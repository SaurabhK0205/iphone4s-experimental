#!/usr/bin/env python3
import os
import pty
import select
import sys
import time

LOG_FILE = "/Users/thismac/projects/found_iphone4s/restore_output.log"

def main():
    with open(LOG_FILE, "w") as log_f:
        log_f.write("=== Restore Automation Started ===\n")

    master, slave = pty.openpty()

    pid = os.fork()
    if pid == 0:
        # Child process
        os.close(master)
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(slave)
        os.chdir("/Users/thismac/Legacy-iOS-Kit")
        os.environ["TERM"] = "xterm-256color"
        # Explicitly DO NOT export SSHPASS so restore.sh calls device_sshpass to initialize $ssh and $scp
        os.environ.pop("SSHPASS", None)
        os.execv("/bin/bash", ["/bin/bash", "./restore.sh"])
        sys.exit(1)

    os.close(slave)

    buffer = ""
    state = "INIT"
    last_action_time = 0

    def write_input(data, desc):
        nonlocal buffer
        print(f"\n[AUTO-DRIVER] >>> {desc} (sending {repr(data)})")
        with open(LOG_FILE, "a") as f:
            f.write(f"\n[AUTO-DRIVER] >>> {desc} (sending {repr(data)})\n")
        os.write(master, data.encode())

    while True:
        r, _, _ = select.select([master, sys.stdin], [], [], 0.1)
        if sys.stdin in r:
            user_in = sys.stdin.read(1)
            os.write(master, user_in.encode())

        if master in r:
            try:
                raw_data = os.read(master, 2048)
            except OSError:
                break
            if not raw_data:
                break

            # Always respond to cursor position queries immediately
            if b"\x1b[6n" in raw_data:
                os.write(master, b"\x1b[24;1R")

            data = raw_data.decode('utf-8', errors='replace')
            sys.stdout.write(data)
            sys.stdout.flush()
            with open(LOG_FILE, "a") as f:
                f.write(data)
                f.flush()

            buffer += data
            if len(buffer) > 8000:
                buffer = buffer[-8000:]

        now = time.time()
        # State machine evaluated continuously
        if now - last_action_time > 0.8:
            if "Select Y to remove all tmp folders" in buffer:
                write_input("Y\n", "Clean tmp folders")
                buffer = ""
                last_action_time = now

            elif state == "INIT" and "> Main Menu" in buffer and "Restore/Downgrade" in buffer:
                time.sleep(0.3)
                write_input("\n", "Select 'Restore/Downgrade' from Main Menu")
                state = "RESTORE_MENU"
                buffer = ""
                last_action_time = now

            elif state == "RESTORE_MENU" and "> Main Menu > Restore/Downgrade" in buffer and "iOS 6.1.3" in buffer:
                time.sleep(0.3)
                write_input("\x1b[B\x1b[B\n", "Select 'iOS 6.1.3'")
                state = "TARGET_MENU"
                buffer = ""
                last_action_time = now

            elif state == "TARGET_MENU" and "Restore/Downgrade > iOS 6.1.3" in buffer and "Start Restore" in buffer:
                time.sleep(0.3)
                write_input("\x1b[B\x1b[B\n", "Select '(*) Start Restore'")
                state = "PROMPTS"
                buffer = ""
                last_action_time = now

            elif state in ("PROMPTS", "RESTORE_IN_PROGRESS"):
                if "Jailbreak Option" in buffer and "Enable this option?" in buffer:
                    time.sleep(0.3)
                    write_input("\n", "Accept default Yes for Jailbreak Option")
                    buffer = ""
                    last_action_time = now
                elif "Hacktivate Option" in buffer and "Enable this option?" in buffer:
                    time.sleep(0.3)
                    write_input("\n", "Accept default No for Hacktivate Option")
                    buffer = ""
                    last_action_time = now
                elif "Memory Option" in buffer and "Enable this option?" in buffer:
                    time.sleep(0.3)
                    write_input("\n", "Accept default Yes for Memory Option")
                    buffer = ""
                    last_action_time = now
                elif "Stashing to free up space" in buffer and "Enable this option?" in buffer:
                    time.sleep(0.3)
                    write_input("\n", "Accept default No for Stashing Option")
                    buffer = ""
                    last_action_time = now
                elif "Mode Option" in buffer and "Select your option:" in buffer:
                    time.sleep(0.3)
                    write_input("\n", "Select default 'kDFU / Jailbroken'")
                    buffer = ""
                    last_action_time = now
                elif "Enter the SSH root password of your iOS device:" in buffer:
                    time.sleep(0.3)
                    write_input("alpine\n", "Enter SSH password 'alpine'")
                    buffer = ""
                    state = "RESTORE_IN_PROGRESS"
                    last_action_time = now

        pid_res, status = os.waitpid(pid, os.WNOHANG)
        if pid_res != 0:
            print(f"\n[AUTO-DRIVER] restore.sh process exited with code {status}")
            break

    os.close(master)

if __name__ == "__main__":
    main()
