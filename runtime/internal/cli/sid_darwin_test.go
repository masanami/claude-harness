package cli

import "syscall"

// getsid は pid のプロセスのセッション ID を返す（runner が新しいセッションで動いていることを確かめるテスト用）。
// macOS の syscall には Getsid がある。Linux は sid_linux_test.go。
func getsid(pid int) (int, error) {
	return syscall.Getsid(pid)
}
