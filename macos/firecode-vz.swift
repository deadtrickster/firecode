// firecode-vz - firecracker's interface over Apple's Virtualization.framework.
//
// firecode drives a VMM through three things: a JSON config file, an HTTP API
// on a unix socket, and vsock behind a unix socket. This speaks exactly those,
// so everything above it - the relays, vsock-exec.py, vsock-cp.py, the
// console, checkpoints - is the code the Linux host runs, unchanged:
//
//   firecode-vz --api-sock firecracker.socket [--config-file vm-config.json]
//
// Run with the jail directory as the working directory, like firecracker;
// relative paths in the config resolve against it.
//
// vsock, the way firecracker does it:
//   host -> guest  connect to <uds_path>, write "CONNECT <port>\n", read
//                  "OK <n>\n", then the stream is the guest's port
//   guest -> host  a guest connecting to the host on <port> is handed to
//                  whatever listens on <uds_path>_<port>
//
// Virtualization.framework wants guest->host ports registered in advance, and
// firecracker discovers them per connection - so the directory is watched and
// every <uds_path>_<port> socket that appears gets a listener.
//
// API, the subset firecode uses:
//   PATCH /vm              {"state":"Paused"|"Resumed"}
//   PUT   /snapshot/create {"snapshot_path":..., "mem_file_path":...}
//   PUT   /snapshot/load   {"snapshot_path":..., "mem_backend":{"backend_path":...}, "resume_vm":bool}
//   PUT   /actions         {"action_type":"SendCtrlAltDel"|"InstanceStart"}
//   GET   /                instance state
//
// A snapshot is Virtualization.framework's saved state (in mem_file_path) plus
// the config it was taken from (in snapshot_path): restoring needs a machine
// configured exactly as the saved one was, and firecracker's own vmstate
// carries that too.

import Darwin
import Foundation
import Virtualization

// MARK: - plumbing

func log(_ s: String) {
	FileHandle.standardError.write("[firecode-vz] \(s)\n".data(using: .utf8)!)
}

func fail(_ s: String) -> Never {
	log("error: \(s)")
	restoreTerminal()
	exit(1)
}

var savedTermios: termios?

func rawTerminal() {
	guard isatty(0) != 0 else { return }
	var t = termios()
	guard tcgetattr(0, &t) == 0 else { return }
	savedTermios = t
	cfmakeraw(&t)
	tcsetattr(0, TCSANOW, &t)
}

func restoreTerminal() {
	guard var t = savedTermios else { return }
	tcsetattr(0, TCSANOW, &t)
	savedTermios = nil
}

/// Run on the VM's queue and wait for it. The machine may only be touched
/// from the queue it was created on; the API server is not that queue.
func onMain<T>(_ body: @escaping (@escaping (T) -> Void) -> Void) -> T {
	let sem = DispatchSemaphore(value: 0)
	var out: T?
	DispatchQueue.main.async {
		body { v in
			out = v
			sem.signal()
		}
	}
	sem.wait()
	return out!
}

func resolve(_ p: String) -> URL {
	if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
	return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(p)
}

func writeAll(_ fd: Int32, _ data: UnsafeRawPointer, _ n: Int) -> Bool {
	var off = 0
	while off < n {
		let w = Darwin.write(fd, data + off, n - off)
		if w < 0 {
			if errno == EINTR { continue }
			return false
		}
		off += w
	}
	return true
}

/// Copy both ways until both sides are done, then close. A half-close is
/// passed on rather than treated as the end: a tar stream finishing in one
/// direction still has an exit status coming back in the other.
func splice(_ a: Int32, _ b: Int32, keep: AnyObject? = nil) {
	let group = DispatchGroup()
	func pump(_ from: Int32, _ to: Int32) {
		group.enter()
		Thread.detachNewThread {
			var buf = [UInt8](repeating: 0, count: 65536)
			while true {
				let n = buf.withUnsafeMutableBytes { Darwin.read(from, $0.baseAddress, 65536) }
				if n < 0 && errno == EINTR { continue }
				if n <= 0 { break }
				let ok = buf.withUnsafeBytes { writeAll(to, $0.baseAddress!, n) }
				if !ok { break }
			}
			shutdown(to, SHUT_WR)
			group.leave()
		}
	}
	pump(a, b)
	pump(b, a)
	Thread.detachNewThread {
		group.wait()
		close(a)
		close(b)
		withExtendedLifetime(keep) {}
	}
}

func unixListen(_ path: String) -> Int32 {
	unlink(path)
	let fd = socket(AF_UNIX, SOCK_STREAM, 0)
	guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
	var addr = sockaddr_un()
	addr.sun_family = sa_family_t(AF_UNIX)
	let bytes = Array(path.utf8)
	guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
		fail("socket path too long: \(path)")
	}
	withUnsafeMutableBytes(of: &addr.sun_path) { p in
		for (i, c) in bytes.enumerated() { p[i] = c }
		p[bytes.count] = 0
	}
	let len = socklen_t(MemoryLayout<sockaddr_un>.size)
	let rc = withUnsafePointer(to: &addr) {
		$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
	}
	guard rc == 0 else { fail("bind \(path): \(String(cString: strerror(errno)))") }
	guard listen(fd, 64) == 0 else { fail("listen \(path): \(String(cString: strerror(errno)))") }
	return fd
}

func unixConnect(_ path: String) -> Int32? {
	let fd = socket(AF_UNIX, SOCK_STREAM, 0)
	guard fd >= 0 else { return nil }
	var addr = sockaddr_un()
	addr.sun_family = sa_family_t(AF_UNIX)
	let bytes = Array(path.utf8)
	guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
		close(fd)
		return nil
	}
	withUnsafeMutableBytes(of: &addr.sun_path) { p in
		for (i, c) in bytes.enumerated() { p[i] = c }
		p[bytes.count] = 0
	}
	let len = socklen_t(MemoryLayout<sockaddr_un>.size)
	let rc = withUnsafePointer(to: &addr) {
		$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
	}
	if rc != 0 {
		close(fd)
		return nil
	}
	return fd
}

/// One line, byte by byte, so nothing after it is swallowed into a buffer
/// the splice never sees.
func readLine(_ fd: Int32, max: Int = 512) -> String? {
	var out = [UInt8]()
	var c: UInt8 = 0
	while out.count < max {
		let n = Darwin.read(fd, &c, 1)
		if n < 0 && errno == EINTR { continue }
		if n <= 0 { return nil }
		if c == UInt8(ascii: "\n") { return String(decoding: out, as: UTF8.self) }
		out.append(c)
	}
	return nil
}

// MARK: - configuration

struct Config {
	var raw: [String: Any]

	init(_ raw: [String: Any]) { self.raw = raw }

	init(file: String) {
		guard let data = FileManager.default.contents(atPath: file),
			var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { fail("cannot read config \(file)") }
		// No RTC: an arm64 guest under Virtualization.framework wakes up in
		// 1970, and every TLS certificate and apt Release file is "not valid
		// yet". The initramfs sets the clock from this before anything looks.
		//
		// Worked out once and kept in the config, because the config is what
		// a snapshot carries, and a restore is refused ("invalid argument")
		// unless the machine is configured exactly as the saved one was -
		// kernel command line included.
		let boot = obj["boot-source"] as? [String: Any] ?? [:]
		let epoch = Int(Date().timeIntervalSince1970)
		obj["firecode-vz-cmdline"] = ((boot["boot_args"] as? String) ?? "") + " firecode.epoch=\(epoch)"
		// The platform's identity is random unless given, and saved state
		// only restores into the machine it was saved from.
		obj["firecode-vz-machine-id"] = VZGenericMachineIdentifier().dataRepresentation.base64EncodedString()
		self.raw = obj
	}

	var vsockPath: String? {
		(raw["vsock"] as? [String: Any])?["uds_path"] as? String
	}

	func build() -> VZVirtualMachineConfiguration {
		let c = VZVirtualMachineConfiguration()
		let platform = VZGenericPlatformConfiguration()
		if let b64 = raw["firecode-vz-machine-id"] as? String, let data = Data(base64Encoded: b64),
			let id = VZGenericMachineIdentifier(dataRepresentation: data) {
			platform.machineIdentifier = id
		}
		c.platform = platform

		guard let boot = raw["boot-source"] as? [String: Any],
			let kernel = boot["kernel_image_path"] as? String
		else { fail("no boot-source.kernel_image_path") }
		let loader = VZLinuxBootLoader(kernelURL: resolve(kernel))
		if let initrd = boot["initrd_path"] as? String { loader.initialRamdiskURL = resolve(initrd) }
		loader.commandLine = (raw["firecode-vz-cmdline"] as? String) ?? (boot["boot_args"] as? String) ?? ""
		c.bootLoader = loader

		let machine = raw["machine-config"] as? [String: Any] ?? [:]
		let vcpu = (machine["vcpu_count"] as? Int) ?? 2
		let mem = (machine["mem_size_mib"] as? Int) ?? 2048
		c.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
			min(vcpu, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
		c.memorySize = UInt64(mem) * 1024 * 1024

		// Drives in the order given: the guest finds its root layers by
		// position, before there is a udev to ask about labels.
		var disks: [VZStorageDeviceConfiguration] = []
		for d in raw["drives"] as? [[String: Any]] ?? [] {
			guard let p = d["path_on_host"] as? String else { continue }
			let ro = (d["is_read_only"] as? Bool) ?? false
			let url = resolve(p)
			var st = stat()
			let isBlock = stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFBLK
			do {
				let att: VZStorageDeviceAttachment
				if isBlock {
					let fh = ro ? FileHandle(forReadingAtPath: url.path) : FileHandle(forUpdatingAtPath: url.path)
					guard let fh else { fail("cannot open \(url.path)") }
					att = try VZDiskBlockDeviceStorageDeviceAttachment(
						fileHandle: fh, readOnly: ro, synchronizationMode: .full)
				} else {
					att = try VZDiskImageStorageDeviceAttachment(
						url: url, readOnly: ro, cachingMode: .automatic, synchronizationMode: .full)
				}
				disks.append(VZVirtioBlockDeviceConfiguration(attachment: att))
			} catch {
				fail("drive \(p): \(error.localizedDescription)")
			}
		}
		c.storageDevices = disks

		// No tap and no bridge: vmnet's NAT, which needs no privilege. The
		// guest takes its address by DHCP, and a fixed MAC gets it the same
		// lease every time.
		var nets: [VZNetworkDeviceConfiguration] = []
		for n in raw["network-interfaces"] as? [[String: Any]] ?? [] {
			let dev = VZVirtioNetworkDeviceConfiguration()
			dev.attachment = VZNATNetworkDeviceAttachment()
			if let m = n["guest_mac"] as? String, let mac = VZMACAddress(string: m) {
				dev.macAddress = mac
			}
			nets.append(dev)
		}
		c.networkDevices = nets

		if raw["vsock"] != nil {
			c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
		}
		if raw["balloon"] != nil {
			c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
		}
		c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

		// The console is hvc0, on our stdin and stdout - which is where
		// firecracker puts ttyS0. Output goes through consoleWatch on the
		// way, which is how a guest reset is noticed.
		let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
		serial.attachment = VZFileHandleSerialPortAttachment(
			fileHandleForReading: FileHandle.standardInput,
			fileHandleForWriting: consoleWatch.pipe.fileHandleForWriting)
		c.serialPorts = [serial]

		do {
			try c.validate()
		} catch {
			fail("invalid machine: \(error.localizedDescription)")
		}
		return c
	}
}

// MARK: - the console, and resets

/// Firecracker exits when its guest resets; Virtualization.framework boots
/// it again, and says nothing - a reboot meant "this run is over" and would
/// instead start the run over. firecode's initramfs prints a marker every
/// boot, so a second one in the same process is a reset, and stops the
/// machine the way firecracker would have.
final class ConsoleWatch {
	static let marker = Array("[firecode-initrd] boot".utf8)
	let pipe = Pipe()
	/// Boots this process is expecting: one when it boots the machine,
	/// none when it restores one that has booted already.
	var expected = 1
	var seen = 0
	var onReset: (() -> Void)?

	func start() {
		let fd = pipe.fileHandleForReading.fileDescriptor
		Thread.detachNewThread { [self] in
			var buf = [UInt8](repeating: 0, count: 65536)
			var at = 0
			while true {
				let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
				if n < 0 && errno == EINTR { continue }
				if n <= 0 { return }
				_ = buf.withUnsafeBytes { writeAll(1, $0.baseAddress!, n) }
				for b in buf[0..<n] {
					if b == ConsoleWatch.marker[at] {
						at += 1
					} else {
						at = b == ConsoleWatch.marker[0] ? 1 : 0
					}
					if at == ConsoleWatch.marker.count {
						at = 0
						seen += 1
						if seen > expected { DispatchQueue.main.async { self.onReset?() } }
					}
				}
			}
		}
	}
}

let consoleWatch = ConsoleWatch()

// MARK: - the machine

final class Machine: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
	var vm: VZVirtualMachine?
	var config: Config?
	var vmConfiguration: VZVirtualMachineConfiguration?
	var vsockPath: String?
	var listened = Set<UInt32>()
	var hostListener: Int32 = -1

	func create(_ cfg: Config) {
		config = cfg
		let built = cfg.build()
		vmConfiguration = built
		let vm = VZVirtualMachine(configuration: built)
		vm.delegate = self
		self.vm = vm
		// As given, not resolved: a unix socket path is capped at 104 bytes
		// here, and a run's directory is longer than that. Relative to the
		// working directory, like firecracker's.
		if let p = cfg.vsockPath {
			vsockPath = p
			startVsock()
		}
	}

	func start() {
		vm!.start { r in
			if case let .failure(e) = r { fail("start: \(e.localizedDescription)") }
		}
	}

	func guestDidStop(_ vm: VZVirtualMachine) {
		restoreTerminal()
		exit(0)
	}

	func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
		fail("the machine stopped: \(error.localizedDescription)")
	}

	var socketDevice: VZVirtioSocketDevice? {
		vm?.socketDevices.first as? VZVirtioSocketDevice
	}

	// MARK: vsock

	func startVsock() {
		guard let path = vsockPath else { return }
		hostListener = unixListen(path)
		let fd = hostListener
		Thread.detachNewThread { [self] in
			while true {
				let c = accept(fd, nil, nil)
				if c < 0 {
					if errno == EINTR { continue }
					return
				}
				Thread.detachNewThread { self.hostConnect(c) }
			}
		}
		// Guest -> host ports: whatever <uds_path>_<port> exists now, and
		// whatever appears later.
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now(), repeating: .milliseconds(500))
		timer.setEventHandler { [self] in self.scanGuestPorts() }
		timer.resume()
		portTimer = timer
	}

	var portTimer: DispatchSourceTimer?

	func scanGuestPorts() {
		guard let path = vsockPath, let dev = socketDevice else { return }
		var dir = (path as NSString).deletingLastPathComponent
		if dir.isEmpty { dir = "." }
		let base = (path as NSString).lastPathComponent + "_"
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
		for n in names where n.hasPrefix(base) {
			guard let port = UInt32(n.dropFirst(base.count)), !listened.contains(port) else { continue }
			let l = VZVirtioSocketListener()
			l.delegate = self
			dev.setSocketListener(l, forPort: port)
			listened.insert(port)
		}
	}

	func listener(_ listener: VZVirtioSocketListener,
		shouldAcceptNewConnection conn: VZVirtioSocketConnection,
		from device: VZVirtioSocketDevice) -> Bool {
		guard let path = vsockPath,
			let up = unixConnect("\(path)_\(conn.destinationPort)")
		else { return false }
		let fd = dup(conn.fileDescriptor)
		splice(fd, up, keep: conn)
		return true
	}

	func hostConnect(_ c: Int32) {
		guard let line = readLine(c),
			line.hasPrefix("CONNECT "),
			let port = UInt32(line.dropFirst(8).trimmingCharacters(in: .whitespaces))
		else {
			close(c)
			return
		}
		let result: Result<VZVirtioSocketConnection, Error>? = onMain { done in
			guard let dev = self.socketDevice else { return done(nil) }
			dev.connect(toPort: port) { done($0) }
		}
		guard case let .success(conn)? = result else {
			// What firecracker does with a port nobody listens on: closes.
			close(c)
			return
		}
		let ok = "OK \(conn.sourcePort)\n"
		_ = ok.withCString { writeAll(c, $0, strlen($0)) }
		let fd = dup(conn.fileDescriptor)
		splice(c, fd, keep: conn)
	}

	// MARK: API

	func pause() -> String? {
		onMain { done in
			guard let vm = self.vm else { return done("no machine") }
			if vm.state == .paused { return done(nil) }
			vm.pause { r in
				if case let .failure(e) = r { done(e.localizedDescription) } else { done(nil) }
			}
		}
	}

	func resume() -> String? {
		onMain { done in
			guard let vm = self.vm else { return done("no machine") }
			if vm.state == .running { return done(nil) }
			vm.resume { r in
				if case let .failure(e) = r { done(e.localizedDescription) } else { done(nil) }
			}
		}
	}

	func snapshotCreate(_ body: [String: Any]) -> String? {
		guard let sp = body["snapshot_path"] as? String,
			let mp = body["mem_file_path"] as? String
		else { return "snapshot_path and mem_file_path are required" }
		guard #available(macOS 14, *) else { return "checkpoints need macOS 14" }
		do {
			try self.vmConfiguration?.validateSaveRestoreSupport()
		} catch {
			return "this machine cannot be saved: \(error.localizedDescription)"
		}
		let err: String? = onMain { done in
			guard let vm = self.vm else { return done("no machine") }
			guard vm.state == .paused else { return done("the machine must be paused first") }
			let mem = resolve(mp)
			try? FileManager.default.removeItem(at: mem)
			vm.saveMachineStateTo(url: mem) { e in done(e?.localizedDescription) }
		}
		if let err { return err }
		guard let raw = config?.raw,
			let data = try? JSONSerialization.data(withJSONObject: ["firecode-vz": 1, "config": raw],
				options: [.prettyPrinted, .sortedKeys]),
			FileManager.default.createFile(atPath: resolve(sp).path, contents: data)
		else { return "could not write \(sp)" }
		return nil
	}

	func snapshotLoad(_ body: [String: Any]) -> String? {
		guard #available(macOS 14, *) else { return "checkpoints need macOS 14" }
		guard vm == nil else { return "a machine is already running" }
		guard let sp = body["snapshot_path"] as? String,
			let mp = (body["mem_backend"] as? [String: Any])?["backend_path"] as? String
				?? body["mem_file_path"] as? String
		else { return "snapshot_path and mem_backend.backend_path are required" }
		guard let data = FileManager.default.contents(atPath: resolve(sp).path),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let raw = obj["config"] as? [String: Any]
		else { return "\(sp) is not a firecode-vz snapshot" }
		let resumeVM = (body["resume_vm"] as? Bool) ?? false
		consoleWatch.expected = 0
		return onMain { done in
			self.create(Config(raw))
			self.vm!.restoreMachineStateFrom(url: resolve(mp)) { e in
				if let e {
					// Not left half-made: a retry has to be able to start over.
					self.vm = nil
					return done("restore: \(e.localizedDescription) \((e as NSError).userInfo)")
				}
				guard resumeVM else { return done(nil) }
				self.vm!.resume { r in
					if case let .failure(e) = r { done(e.localizedDescription) } else { done(nil) }
				}
			}
		}
	}

	func action(_ body: [String: Any]) -> String? {
		switch body["action_type"] as? String {
		case "SendCtrlAltDel":
			return onMain { done in
				guard let vm = self.vm else { return done("no machine") }
				do { try vm.requestStop() ; done(nil) } catch { done(error.localizedDescription) }
			}
		case "InstanceStart":
			return onMain { done in
				guard self.vm != nil else { return done("no machine configured") }
				self.start()
				done(nil)
			}
		default:
			return "unsupported action"
		}
	}

	func state() -> String {
		onMain { done in
			switch self.vm?.state {
			case .running?: done("Running")
			case .paused?: done("Paused")
			case nil: done("Not started")
			default: done("Other")
			}
		}
	}
}

// MARK: - HTTP over the API socket

func serveAPI(_ path: String, _ m: Machine) {
	let fd = unixListen(path)
	Thread.detachNewThread {
		while true {
			let c = accept(fd, nil, nil)
			if c < 0 {
				if errno == EINTR { continue }
				return
			}
			Thread.detachNewThread { handle(c, m) }
		}
	}
}

func handle(_ c: Int32, _ m: Machine) {
	defer { close(c) }
	while true {
		guard let request = readLine(c, max: 8192) else { return }
		let parts = request.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
		guard parts.count >= 2 else { return }
		let method = String(parts[0]), path = String(parts[1])
		var length = 0
		var keepAlive = true
		while let h = readLine(c, max: 8192) {
			let line = h.trimmingCharacters(in: .whitespacesAndNewlines)
			if line.isEmpty { break }
			let kv = line.split(separator: ":", maxSplits: 1).map {
				$0.trimmingCharacters(in: .whitespaces).lowercased()
			}
			if kv.count == 2 && kv[0] == "content-length" { length = Int(kv[1]) ?? 0 }
			if kv.count == 2 && kv[0] == "connection" && kv[1] == "close" { keepAlive = false }
		}
		var body = [UInt8](repeating: 0, count: length)
		var got = 0
		while got < length {
			let n = body.withUnsafeMutableBytes { Darwin.read(c, $0.baseAddress! + got, length - got) }
			if n <= 0 { return }
			got += n
		}
		let json = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:]

		var status = 204
		var out = ""
		var err: String?
		switch (method, path) {
		case ("PATCH", "/vm"):
			switch json["state"] as? String {
			case "Paused": err = m.pause()
			case "Resumed": err = m.resume()
			default: err = "state must be Paused or Resumed"
			}
		case ("PUT", "/snapshot/create"): err = m.snapshotCreate(json)
		case ("PUT", "/snapshot/load"): err = m.snapshotLoad(json)
		case ("PUT", "/actions"): err = m.action(json)
		case ("GET", "/"):
			status = 200
			out = "{\"id\":\"firecode-vz\",\"state\":\"\(m.state())\",\"vmm_version\":\"firecode-vz\"}"
		case (_, let p) where p.hasPrefix("/drives/"):
			err = "Virtualization.framework cannot resize a drive under a running guest"
		default:
			status = 400
			err = "unsupported: \(method) \(path)"
		}
		if let err {
			status = 400
			let msg = (try? JSONSerialization.data(withJSONObject: ["fault_message": err]))
				.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
			out = msg
		}
		let reason = [200: "OK", 204: "No Content", 400: "Bad Request"][status] ?? ""
		var resp = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
		resp += "Content-Length: \(out.utf8.count)\r\n\r\n\(out)"
		let ok = resp.withCString { writeAll(c, $0, strlen($0)) }
		if !ok || !keepAlive { return }
	}
}

// MARK: - main

var apiSock: String?
var configFile: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
	switch a {
	case "--api-sock": apiSock = args.next()
	case "--config-file": configFile = args.next()
	case "--version":
		print("firecode-vz 1")
		exit(0)
	// firecracker's other flags (--id, --level, --log-path ...) mean nothing
	// here; their values are skipped with them.
	case let f where f.hasPrefix("--"):
		_ = args.next()
	default: break
	}
}

var signalSources: [DispatchSourceSignal] = []
signal(SIGPIPE, SIG_IGN)
let machine = Machine()
consoleWatch.onReset = {
	log("the guest reset - stopping, as firecracker would")
	machine.vm?.stop { _ in
		restoreTerminal()
		exit(0)
	}
}
consoleWatch.start()
for sig in [SIGINT, SIGTERM, SIGHUP] {
	signal(sig, SIG_IGN)
	let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
	src.setEventHandler {
		restoreTerminal()
		exit(128 + sig)
	}
	src.resume()
	signalSources.append(src)
}

if let apiSock { serveAPI(apiSock, machine) }
if let configFile {
	machine.create(Config(file: resolve(configFile).path))
	rawTerminal()
	machine.start()
} else if apiSock == nil {
	fail("usage: firecode-vz --api-sock PATH [--config-file PATH]")
}
dispatchMain()
