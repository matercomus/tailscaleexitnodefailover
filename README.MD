# Tailscale Exit Node Auto-Switch Script

This script automates the process of managing and switching between exit nodes in a Tailscale network based on ICMP (ping) test results. 
It ensures that the best available exit node is being used, with options for fallback behavior when no exit node is available.

## Features
- Automatically checks and switches to the best available exit node.
- Performs ICMP tests to verify internet connectivity.
- Supports fail-open functionality to maintain connectivity even if no exit nodes are available.
- Configurable via a set of variables for customization.

## Prerequisites
- **Tailscale** must be installed and configured on your system.
- Root or `sudo` access is required to run the `tailscale up` command.
  
## Usage

### Step 1: Configuration
Edit the following variables in the script to match your environment:

- `inettestip`: The IP address used to test for internet connectivity (default: `8.8.8.8`).
- `exitnodes`: A prioritized list of IP addresses for your Tailscale exit nodes.
- `failopen`: Set to `true` if you want to maintain internet access without an exit node when all nodes are down. Set to `false` to keep the exit node even if it is down.
- `flags`: Additional Tailscale flags, such as `--advertise-routes` for route advertisement.

### Step 2: Schedule with Cron
To automate the execution of this script every 5 minutes, you can add it to `cron` as follows:

*/5 * * * * /path/to/tsfailover.sh >> /path/to/logfile.log 2>&1

