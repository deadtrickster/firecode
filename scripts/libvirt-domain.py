#!/usr/bin/env python3
"""A libvirt domain that boots the same guest firecracker does.

firecracker is the right VMM for almost everything here: it starts in
milliseconds, restores a snapshot in sixty, and has no device model to speak
of. That last part is also why it cannot do this - there is no PCI bus, so
there is no passing a GPU into a VM, and no amount of harness fixes that.

So there are two backends, and only the boot differs. Everything above it -
the layered root, the drives, the channels the agent talks over, the guest
setup - is identical, because all of it rides on vsock and virtio-blk, which
qemu has too. The guest image does not know which hypervisor started it.

Written as XML for libvirt rather than a qemu command line: libvirt already
solves the parts that are tedious and easy to get wrong - device permissions
for a passed-through GPU, hugepages, cgroup placement, and cleaning up after a
domain that died badly.

usage: libvirt-domain.py <spec.json>     prints the domain XML
"""

import json
import sys
import xml.etree.ElementTree as ET


def indent(elem, level=0):
    pad = "\n" + "  " * level
    if len(elem):
        if not (elem.text or "").strip():
            elem.text = pad + "  "
        for child in elem:
            indent(child, level + 1)
        if not (child.tail or "").strip():
            child.tail = pad
    if level and not (elem.tail or "").strip():
        elem.tail = pad


def build(spec):
    dom = ET.Element("domain", type="kvm")
    ET.SubElement(dom, "name").text = spec["name"]
    ET.SubElement(dom, "memory", unit="MiB").text = str(spec["mem_mib"])
    ET.SubElement(dom, "vcpu").text = str(spec["vcpus"])

    # Pinned vCPUs, when asked for.
    #
    # A vector kernel's timing is only meaningful if it ran on the same core
    # each time. Unpinned, the scheduler moves a vCPU between physical cores
    # mid-measurement - across cache boundaries, and on a hybrid part between
    # cores with different vector throughput entirely - and two runs of
    # identical code differ by more than the change being measured.
    if spec.get("pin"):
        tune = ET.SubElement(dom, "cputune")
        for vcpu, cpu in enumerate(spec["pin"]):
            ET.SubElement(tune, "vcpupin", vcpu=str(vcpu), cpuset=str(cpu))

    # Boot the kernel directly, exactly as firecracker does - same image, same
    # initramfs, same command line. A bootloader would mean a different root
    # assembly path, and then the two backends would be running different
    # guests while claiming to run the same one.
    os_el = ET.SubElement(dom, "os")
    ET.SubElement(os_el, "type", arch="x86_64", machine="q35").text = "hvm"
    ET.SubElement(os_el, "kernel").text = spec["kernel"]
    ET.SubElement(os_el, "initrd").text = spec["initrd"]
    ET.SubElement(os_el, "cmdline").text = spec["cmdline"]

    features = ET.SubElement(dom, "features")
    ET.SubElement(features, "acpi")
    ET.SubElement(features, "apic")
    # A virtual PMU, which is the whole point of this backend for anyone
    # measuring code rather than just running it: cycles, instructions, cache
    # misses, branch mispredicts. firecracker masks CPUID leaf 0xA outright and
    # cannot be asked for them at all.
    #
    # It also needs the host to allow it - kvm's enable_pmu is a load-time
    # parameter and ships off on some distributions - and that is invisible
    # from in here: the guest simply comes up with no cpu PMU and perf reports
    # <not supported> for every hardware event.
    if spec.get("pmu", True):
        ET.SubElement(features, "pmu", state="on")

    # host-passthrough so the guest sees the real CPU. firecracker masks a
    # great deal by default - which is why perf finds no PMU there - and the
    # whole reason to be on this backend is to get at hardware.
    ET.SubElement(dom, "cpu", mode="host-passthrough", check="none")
    ET.SubElement(dom, "on_poweroff").text = "destroy"
    ET.SubElement(dom, "on_reboot").text = "destroy"
    ET.SubElement(dom, "on_crash").text = "destroy"

    # Do not relabel anything.
    #
    # libvirt's DAC driver chowns every file it is given to qemu's user, which
    # for these files is actively wrong: the drives, the base image and the
    # kernel are shared with the *other* backend, where firecracker runs as
    # the person who asked for the VM. One libvirt boot left the 6G base image
    # owned by libvirt-qemu:kvm - still readable, so nothing broke loudly, and
    # one mode change away from every firecracker run failing to find its root.
    #
    # qemu runs as root here and can read them without any of that.
    #
    # Only under a system connection: a session one runs qemu as the caller,
    # has no security driver at all, and rejects the element outright.
    if spec.get("seclabel", True):
        ET.SubElement(dom, "seclabel", type="none", model="dac", relabel="no")

    dev = ET.SubElement(dom, "devices")
    ET.SubElement(dev, "emulator").text = spec.get("emulator", "/usr/bin/qemu-system-x86_64")

    # Drives in the order firecracker attaches them, because the guest finds
    # several of them by position: the root layers come off the kernel command
    # line as /dev/vdN, and an attached dataset is "the last N disks".
    for i, d in enumerate(spec["drives"]):
        disk = ET.SubElement(dev, "disk", type="block" if d.get("block") else "file",
                             device="disk")
        ET.SubElement(disk, "driver", name="qemu", type="raw", cache="none", io="native")
        src = ET.SubElement(disk, "source")
        src.set("dev" if d.get("block") else "file", d["path"])
        ET.SubElement(disk, "target", dev="vd" + chr(ord("a") + i), bus="virtio")
        if d.get("readonly"):
            ET.SubElement(disk, "readonly")

    # The channels. Identical to firecracker's from the guest's side - it
    # listens on the same ports - but the host reaches them as AF_VSOCK rather
    # than through a unix socket with a handshake.
    vsock = ET.SubElement(dev, "vsock", model="virtio")
    ET.SubElement(vsock, "cid", auto="no", address=str(spec["cid"]))

    if spec.get("tap"):
        iface = ET.SubElement(dev, "interface", type="ethernet")
        ET.SubElement(iface, "target", dev=spec["tap"], managed="no")
        ET.SubElement(iface, "model", type="virtio")
        if spec.get("mac"):
            ET.SubElement(iface, "mac", address=spec["mac"])

    console = ET.SubElement(dev, "serial", type="file")
    ET.SubElement(console, "source", path=spec["console_log"])
    ET.SubElement(console, "target", port="0")

    # The point of this backend. A GPU is a PCI device the host has to have
    # let go of first: bound to vfio-pci, in an IOMMU group of its own, and
    # not in use by anything here.
    for addr in spec.get("pci", []):
        dom_id, rest = ("0x0000", addr) if addr.count(":") < 2 else addr.split(":", 1)
        bus, rest = rest.split(":", 1)
        slot, func = rest.split(".", 1)
        hostdev = ET.SubElement(dev, "hostdev", mode="subsystem", type="pci",
                                managed="yes")
        srcel = ET.SubElement(hostdev, "source")
        ET.SubElement(srcel, "address", domain="0x" + dom_id.lstrip("0x").zfill(4),
                      bus="0x" + bus, slot="0x" + slot, function="0x" + func)

    # Memory that is not moved around underneath a device doing DMA. Required
    # for passthrough, and it is what makes the guest's whole footprint
    # resident up front - the same trade firecracker makes when it allocates.
    if spec.get("pci"):
        mb = ET.SubElement(dom, "memoryBacking")
        ET.SubElement(mb, "locked")
        ET.SubElement(dom, "memtune")

    indent(dom)
    return ET.tostring(dom, encoding="unicode")


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    with open(argv[0]) as fh:
        print(build(json.load(fh)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
