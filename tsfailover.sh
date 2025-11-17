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

#<====== Functions ======>
function send_notification () { #pass title and message
if [ "$enable_notifications" != "true" ]; then
	return
fi

local title="$1"
local message="$2"
local urgency="${3:-normal}"  # low, normal, critical

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

function notify_error () { #pass error message
send_notification "ERROR" "$1" "critical"
}

function notify_switch () { #pass exit node name
send_notification "Exit Node Switched" "Now using: $1" "normal"
}

function notify_fallback () { #pass location
send_notification "Using Fallback" "Primary nodes unavailable, using exit nodes from: $1" "normal"
}
function set_exit_node () { #pass string with IP of desired exit node #return true/false for internet working on that exit node.
check_current_exit_node
if [ $1 == false ] && [ $curexitnode != false ] && [ $failopen == true ]; then
	echo "No best exit node, removing exit node..."
	send_notification "Exit Node Removed" "No working exit nodes found, removed exit node (failopen enabled)" "normal"
	sudo tailscale up  $flags --reset
	test_icmp $inettestip
	if $icmp; then
		echo "ICMP to $inettestip is working with exit node removed."
	else
		echo "ICMP to $inettestip is not working with exit node removed. Local Internet issue."
		notify_error "Internet not working after removing exit node - local connection issue"
	fi
elif [ $1 == false ] && [ $curexitnode != false ] && [ $failopen == false ]; then
	echo "There are no working exit nodes but fail open is false so keeping bad exit node."
elif [ $1 != false ] && [ $curexitnode != $1 ]; then
	echo "Setting exit node to $1."
	sudo tailscale up --exit-node $1 $flags
	check_current_exit_node
	if [ $curexitnode == $1 ]; then
		echo "Current exit node sucesfully changed to $curexitnode."
		test_icmp $inettestip
	if $icmp; then
		echo "ICMP to $inettestip is working via exit node $curexitnode."
		notify_switch "$curexitnode"
	else
		echo "ERROR, ICMP to $inettestip is failing via exit node $curexitnode."
		notify_error "ICMP test failing via exit node $curexitnode"
	fi
else
	echo "ERROR, unable to change exit node. Current exit node is $curexitnode."
	notify_error "Unable to change exit node. Current: $curexitnode, Desired: $1"
fi
fi
}

function test_icmp () { #pass string with ip or hostname to test icmp #updates icmp variable with true/false
# Try to resolve hostname to IP if it's a hostname (contains dots but not just numbers)
test_target=$1
if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	# It's an IP address, use as-is
	test_target=$1
else
	# It's a hostname, try to resolve from tailscale status
	resolved_ip=$(tailscale status | grep "$1" | awk '{print $1}' | head -1)
	if [ -n "$resolved_ip" ] && [[ $resolved_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		test_target=$resolved_ip
	else
		# Can't resolve, try pinging the hostname directly (might work if in /etc/hosts or DNS)
		test_target=$1
	fi
fi

ping $test_target -c 4 > ping.test 2>&1
count=$(cat ping.test | grep "bytes from" --count)
#echo $count
if  [ $count -gt 0 ]; then
	echo "$1 is ICMP reachable."
	icmp=true
else
	echo "$1 is ICMP unreachable."
	icmp=false
fi
}

function check_exit_node () { #pass string with IP of exit node. #updates goodenode with true/false
echo "Checking $1 ..."
test_icmp $1
testenode=$(tailscale status | grep "exit node" | grep $1 --count)
if [ $testenode -gt 0 ] && $icmp ; then
    goodenode=true
else
    goodenode=false
fi
}

function check_current_exit_node () { #no input #returns ip and hostname of current exit node
														# ^ added to only get first IP on the line
enodeb=$(tailscale status | grep "; exit node" | grep -E "^(\b25[0-5]|\b2[0-4][0-9]|\b[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}" --count )
if [ $enodeb -gt 0 ]; then
	curexitnode_ip=$(tailscale status | grep "; exit node" | grep -E "^(\b25[0-5]|\b2[0-4][0-9]|\b[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}" -o )
	# Extract hostname from the same line (second field after IP)
	curexitnode_hostname=$(tailscale status | grep "; exit node" | awk '{print $2}')
	# Store both for comparison - use hostname if available, otherwise IP
	if [ -n "$curexitnode_hostname" ] && [ "$curexitnode_hostname" != "" ]; then
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

function discover_exit_nodes_by_location () { #pass location filter string #returns array of hostnames
local location=$1
local discovered_nodes=()
local exit_node_list=$(tailscale exit-node list --filter="$location" 2>/dev/null)
if [ -n "$exit_node_list" ]; then
	# Parse the output to extract hostnames (skip header lines and comments)
	while IFS= read -r line; do
		# Skip header lines and comments
		if [[ $line =~ ^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+ ]]; then
			# Extract hostname (second field)
			hostname=$(echo "$line" | awk '{print $2}')
			if [ -n "$hostname" ] && [[ ! $hostname =~ ^# ]]; then
				discovered_nodes+=("$hostname")
			fi
		fi
	done <<< "$exit_node_list"
fi
echo "${discovered_nodes[@]}"
}

function find_best_exit_node () { #no input #returns ip of best working exit node
bestexitnode=false
# First, try primary exit nodes
for node in "${exitnodes[@]}"
do
check_exit_node $node
if $goodenode; then
	echo "the best exit node is $node."
	bestexitnode=$node
	break
else
	echo "$node is offline, or not configured to be an exit node."
fi
done

# If no primary nodes work, try fallback locations
if [ $bestexitnode == false ] && [ ${#fallback_locations[@]} -gt 0 ]; then
	echo "Primary exit nodes unavailable, trying fallback locations..."
	for location in "${fallback_locations[@]}"
	do
		echo "Searching for exit nodes in $location..."
		discovered_nodes=($(discover_exit_nodes_by_location "$location"))
		if [ ${#discovered_nodes[@]} -gt 0 ]; then
			for node in "${discovered_nodes[@]}"
			do
				check_exit_node $node
				if $goodenode; then
					echo "Found working fallback exit node: $node (from $location)."
					notify_fallback "$location"
					bestexitnode=$node
					break 2
				else
					echo "$node is offline, or not configured to be an exit node."
				fi
			done
		else
			echo "No exit nodes found for location: $location"
		fi
	done
fi

if [ $bestexitnode == false ]; then
	echo "No exit nodes are online and capable of relaying traffic."
	notify_error "All exit nodes are offline or unavailable"
fi
}



#<====== Main program ======>
echo "<====== $(date) ======>"
test_icmp $inettestip
check_current_exit_node

#if block for internet ICMP working
if $icmp && [ $curexitnode != false ]; then
	echo "Internet is up using $curexitnode as an exit node."
	find_best_exit_node
	if [ $bestexitnode == $curexitnode ]; then
		echo "The current exit node is the best exit node."
	elif [ $bestexitnode != false ]; then
		echo "The current exit node is not the best exit node. Switch to best exit node $bestexitnode."
		set_exit_node $bestexitnode
	else 
		echo "all exit nodes are down."
		notify_error "All primary exit nodes are down"
	fi
elif $icmp && [ $curexitnode == false ]; then
	echo "Internet is up but not using an exit node."
	find_best_exit_node
	set_exit_node $bestexitnode
fi

#check again to see if anything changed after first if block
check_current_exit_node
test_icmp $inettestip
#if block for ICMP not working
if [ $icmp == false ] && [ $curexitnode == false ]; then
	echo "Internet is down and there is not an exit node. Local Internet issue."
	notify_error "Local Internet connection is down (no exit node configured)"
elif [ $icmp == false ] && [ $curexitnode != false ]; then
	echo "Internet is down using exit node $curexitnode. Looking for other exit nodes..."
	notify_error "Internet down via exit node $curexitnode, searching for alternatives..."
	find_best_exit_node
	set_exit_node $bestexitnode
elif [ $icmp == true ] && [ $curexitnode == false ]; then
	echo "Internet is working without an exit node."
fi
echo "<======  ======>"
