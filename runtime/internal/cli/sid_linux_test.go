package cli

import "syscall"

// getsid は pid のプロセスのセッション ID を返す（runner が新しいセッションで動いていることを確かめるテスト用）。
// Linux の syscall には Getsid が無いので、getsid(2) のシステムコールを直接呼ぶ。macOS は sid_darwin_test.go。
func getsid(pid int) (int, error) {
	sid, _, errno := syscall.RawSyscall(syscall.SYS_GETSID, uintptr(pid), 0, 0)
	if errno != 0 {
		return 0, errno
	}
	return int(sid), nil
}
