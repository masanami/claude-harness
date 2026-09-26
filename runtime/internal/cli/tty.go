package cli

import (
	"os"
	"syscall"
	"unsafe"
)

// isTerminal は f が端末（TTY）かを返す。端末の属性を読めるか（ioctl）で判定する。/dev/null のような
// 端末でない文字デバイスは偽になる（ModeCharDevice だけでは区別できない）。
func isTerminal(f *os.File) bool {
	if f == nil {
		return false
	}
	var t syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(ioctlGetTermios), uintptr(unsafe.Pointer(&t)))
	return errno == 0
}
