#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define ROOT "/dev/mmcblk2p1"
#define INIT "/sbin/pb626-emmc-init"
#define GADGET "/sys/kernel/config/usb_gadget/pb626"

static void write_text(const char *path, const char *text, size_t size)
{
    int fd = open(path, O_WRONLY | O_NOCTTY);

    if (fd >= 0) {
        write(fd, text, size);
        close(fd);
    }
}

#define WRITE_TEXT(path, text) write_text(path, text, sizeof(text) - 1)

static void mark_boot(unsigned char stage)
{
    const unsigned char reg[] = {0x0e, stage};
    int fd = open("/dev/i2c-0", O_RDWR);

    if (fd >= 0) {
        if (ioctl(fd, I2C_SLAVE_FORCE, 0x34) == 0)
            write(fd, reg, sizeof(reg));
        close(fd);
    }
}

static void stop_boot(unsigned char stage, const char *message, size_t size)
{
    mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    mount("sysfs", "/sys", "sysfs", 0, 0);
    mark_boot(stage);
    WRITE_TEXT("/sys/class/leds/led/trigger", "heartbeat");

    mount("configfs", "/sys/kernel/config", "configfs", 0, 0);
    mkdir(GADGET, 0755);
    WRITE_TEXT(GADGET "/idVendor", "0x0525");
    WRITE_TEXT(GADGET "/idProduct", "0xa4a7");
    mkdir(GADGET "/configs/c.1", 0755);
    mkdir(GADGET "/functions/acm.usb0", 0755);
    symlink(GADGET "/functions/acm.usb0", GADGET "/configs/c.1/acm.usb0");
    WRITE_TEXT(GADGET "/UDC", "musb-hdrc.1.auto");

    for (;;) {
        write_text("/dev/kmsg", message, size);
        write_text("/dev/ttyGS0", message, size);
        sleep(5);
    }
}

#define STOP_BOOT(stage, text) stop_boot(stage, text, sizeof(text) - 1)

int main(void)
{
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, 0) < 0 ||
        mount("sysfs", "/sys", "sysfs", 0, 0) < 0)
        STOP_BOOT(0x7f, "PB626: cannot initialize early userspace\r\n");

    mark_boot(0x70);
    WRITE_TEXT("/sys/class/leds/led/trigger", "heartbeat");

    for (int attempt = 0; attempt < 15 && access(ROOT, F_OK) < 0; ++attempt)
        sleep(1);

    if (mount(ROOT, "/newroot", "ext4", 0, 0) < 0 ||
        access("/newroot" INIT, X_OK) < 0)
        STOP_BOOT(0x7e, "PB626: cannot boot Alpine from " ROOT "\r\n");

    mark_boot(0x71);
    if (chdir("/newroot") < 0 || umount2("/sys", MNT_DETACH) < 0 ||
        umount2("/dev", MNT_DETACH) < 0 || mount(".", "/", 0, MS_MOVE, 0) < 0 ||
        chroot(".") < 0 || chdir("/") < 0)
        STOP_BOOT(0x7f, "PB626: cannot switch to the eMMC root\r\n");

    execl(INIT, INIT, (char *)0);
    STOP_BOOT(0x7f, "PB626: cannot start Alpine init\r\n");
    return 1;
}
