#!/bin/bash

# Edit These Variables
###########################################################
#internet test IP
inettestip=8.8.8.8
#prioritized list of exit node tailscale hostnames or IPs (seperated by spaces)
exitnodes=("nl-ams-wg-008.mullvad.ts.net" "hk-hkg-wg-201.mullvad.ts.net" "jp-tyo-wg-001.mullvad.ts.net" "prox-tailscale.tail496815.ts.net")
#fallback location filters to search for exit nodes when primary nodes are unavailable (space-separated, e.g. "Poland" "Hong Kong")
fallback_locations=("Poland" "Hong Kong")
#set to false to never remove exit node even if all are down
failopen=true
#other tailscale flags, ie. "--advertise-routes=192.169.1.0/24"
flags="--exit-node-allow-lan-access=true"
#enable notifications (true/false)
enable_notifications=true
############################################################

#<====== Helper Functions ======>
function is_false() {
	[ "$1" == "false" ]
}

function is_true() {
	[ "$1" == "true" ]
}

function get_tailscale_status() {
	tailscale status 2>/dev/null
}

#<====== Notification Functions ======>
function send_notification() {
	if ! is_true "$enable_notifications"; then
		return
	fi

	local title="$1"
	local message="$2"
	local urgency="${3:-normal}"

	# Try notify-send first (desktop notifications)
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -u "$urgency" "Tailscale Exit Node: $title" "$message" 2>/dev/null
	fi

	# Also try wall (system-wide message)
	if command -v wall >/dev/null 2>&1; then
		echo "Tailscale Exit Node: $title - $message" | wall 2>/dev/null
	fi

	# Log to notification file
	local notif_log="/tmp/tailscale-exitnode-notifications.log"
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $title: $message" >> "$notif_log"
}

function notify_error() {
	send_notification "ERROR" "$1" "critical"
}

function notify_switch() {
	send_notification "Exit Node Switched" "Now using: $1" "normal"
}

function notify_fallback() {
	send_notification "Using Fallback" "Primary nodes unavailable, using exit nodes from: $1" "normal"
}

#<====== Core Functions ======>
function resolve_hostname_to_ip() {
	local hostname=$1
	local resolved_ip=$(get_tailscale_status | grep "$hostname" | awk '{print $1}' | head -1)
	
	if [ -n "$resolved_ip" ] && [[ $resolved_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "$resolved_ip"
	else
		echo "$hostname"
	fi
}

function test_icmp() {
	local target=$1
	local test_target
	
	# Resolve hostname to IP if needed
	if [[ $target =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		test_target=$target
	else
		test_target=$(resolve_hostname_to_ip "$target")
	fi

	ping "$test_target" -c 4 > ping.test 2>&1
	local count=$(grep -c "bytes from" ping.test 2>/dev/null || echo "0")
	
	if [ $count -gt 0 ]; then
		echo "$target is ICMP reachable."
		icmp=true
	else
		echo "$target is ICMP unreachable."
		icmp=false
	fi
}

function check_current_exit_node() {
	local status_line=$(get_tailscale_status | grep "; exit node")
	local ip_pattern='^(\b25[0-5]|\b2[0-4][0-9]|\b[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}'
	
	if echo "$status_line" | grep -qE "$ip_pattern"; then
		curexitnode_ip=$(echo "$status_line" | grep -oE "$ip_pattern")
		curexitnode_hostname=$(echo "$status_line" | awk '{print $2}')
		
		if [ -n "$curexitnode_hostname" ]; then
			curexitnode="$curexitnode_hostname"
		else
			curexitnode="$curexitnode_ip"
		fi
	else
		curexitnode=false
		curexitnode_ip=false
		curexitnode_hostname=false
	fi
}

function check_exit_node() {
	local node=$1
	echo "Checking $node ..."
	
	test_icmp "$node"
	local is_exit_node=$(get_tailscale_status | grep "exit node" | grep -c "$node" || echo "0")
	
	if [ $is_exit_node -gt 0 ] && is_true "$icmp"; then
		goodenode=true
	else
		goodenode=false
	fi
}

function try_exit_nodes() {
	local nodes=("$@")
	local best_node=false
	
	for node in "${nodes[@]}"; do
		check_exit_node "$node"
		if is_true "$goodenode"; then
			echo "Found working exit node: $node."
			best_node=$node
			break
		else
			echo "$node is offline, or not configured to be an exit node."
		fi
	done
	
	echo "$best_node"
}

function discover_exit_nodes_by_location() {
	local location=$1
	local discovered_nodes=()
	local exit_node_list=$(tailscale exit-node list --filter="$location" 2>/dev/null)
	
	if [ -n "$exit_node_list" ]; then
		while IFS= read -r line; do
			if [[ $line =~ ^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+ ]]; then
				local hostname=$(echo "$line" | awk '{print $2}')
				if [ -n "$hostname" ] && [[ ! $hostname =~ ^# ]]; then
					discovered_nodes+=("$hostname")
				fi
			fi
		done <<< "$exit_node_list"
	fi
	
	echo "${discovered_nodes[@]}"
}

function find_best_exit_node() {
	# Try primary exit nodes first
	local best_node=$(try_exit_nodes "${exitnodes[@]}")
	
	# If no primary nodes work, try fallback locations
	if is_false "$best_node" && [ ${#fallback_locations[@]} -gt 0 ]; then
		echo "Primary exit nodes unavailable, trying fallback locations..."
		for location in "${fallback_locations[@]}"; do
			echo "Searching for exit nodes in $location..."
			local discovered_nodes=($(discover_exit_nodes_by_location "$location"))
			
			if [ ${#discovered_nodes[@]} -gt 0 ]; then
				best_node=$(try_exit_nodes "${discovered_nodes[@]}")
				if ! is_false "$best_node"; then
					notify_fallback "$location"
					break
				fi
			else
				echo "No exit nodes found for location: $location"
			fi
		done
	fi
	
	if is_false "$best_node"; then
		echo "No exit nodes are online and capable of relaying traffic."
		notify_error "All exit nodes are offline or unavailable"
	fi
	
	bestexitnode=$best_node
}

function verify_exit_node_connectivity() {
	local node=$1
	test_icmp "$inettestip"
	
	if is_true "$icmp"; then
		echo "ICMP to $inettestip is working via exit node $node."
		notify_switch "$node"
		return 0
	else
		echo "ERROR, ICMP to $inettestip is failing via exit node $node."
		notify_error "ICMP test failing via exit node $node"
		return 1
	fi
}

function remove_exit_node() {
	echo "No best exit node, removing exit node..."
	send_notification "Exit Node Removed" "No working exit nodes found, removed exit node (failopen enabled)" "normal"
	sudo tailscale up $flags --reset
	
	test_icmp "$inettestip"
	if is_true "$icmp"; then
		echo "ICMP to $inettestip is working with exit node removed."
	else
		echo "ICMP to $inettestip is not working with exit node removed. Local Internet issue."
		notify_error "Internet not working after removing exit node - local connection issue"
	fi
}

function set_exit_node() {
	local desired_node=$1
	check_current_exit_node
	
	# Handle removal case
	if is_false "$desired_node" && ! is_false "$curexitnode"; then
		if is_true "$failopen"; then
			remove_exit_node
		else
			echo "There are no working exit nodes but fail open is false so keeping bad exit node."
		fi
		return
	fi
	
	# Handle setting new exit node
	if ! is_false "$desired_node" && [ "$curexitnode" != "$desired_node" ]; then
		echo "Setting exit node to $desired_node."
		sudo tailscale up --exit-node "$desired_node" $flags
		check_current_exit_node
		
		if [ "$curexitnode" == "$desired_node" ]; then
			echo "Current exit node successfully changed to $curexitnode."
			verify_exit_node_connectivity "$curexitnode"
		else
			echo "ERROR, unable to change exit node. Current exit node is $curexitnode."
			notify_error "Unable to change exit node. Current: $curexitnode, Desired: $desired_node"
		fi
	fi
}

#<====== Main program ======>
function main() {
	echo "<====== $(date) ======>"
	
	# Initial connectivity check
	test_icmp "$inettestip"
	check_current_exit_node
	
	# Determine action based on current state
	if is_true "$icmp" && ! is_false "$curexitnode"; then
		# Internet working with exit node
		echo "Internet is up using $curexitnode as an exit node."
		find_best_exit_node
		
		if [ "$bestexitnode" == "$curexitnode" ]; then
			echo "The current exit node is the best exit node."
		elif ! is_false "$bestexitnode"; then
			echo "The current exit node is not the best exit node. Switch to best exit node $bestexitnode."
			set_exit_node "$bestexitnode"
		else
			echo "All exit nodes are down."
			notify_error "All primary exit nodes are down"
		fi
		
	elif is_true "$icmp" && is_false "$curexitnode"; then
		# Internet working without exit node
		echo "Internet is up but not using an exit node."
		find_best_exit_node
		set_exit_node "$bestexitnode"
		
	elif is_false "$icmp"; then
		# Internet not working - recheck and handle
		check_current_exit_node
		test_icmp "$inettestip"
		
		if is_false "$icmp" && is_false "$curexitnode"; then
			echo "Internet is down and there is not an exit node. Local Internet issue."
			notify_error "Local Internet connection is down (no exit node configured)"
		elif is_false "$icmp" && ! is_false "$curexitnode"; then
			echo "Internet is down using exit node $curexitnode. Looking for other exit nodes..."
			notify_error "Internet down via exit node $curexitnode, searching for alternatives..."
			find_best_exit_node
			set_exit_node "$bestexitnode"
		elif is_true "$icmp" && is_false "$curexitnode"; then
			echo "Internet is working without an exit node."
		fi
	fi
	
	echo "<======  ======>"
}

main
