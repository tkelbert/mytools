#!/usr/bin/env bash
# Emulate full Windows ipconfig /all output on Linux Mint

# ----------------- Helper Functions -----------------
cidr_to_mask() {
    local cidr=$1
    local mask=""
    local full_octets=$(( cidr / 8 ))
    local partial_octet=$(( cidr % 8 ))

    for ((i=0; i<4; i++)); do
        if [ $i -lt $full_octets ]; then
            mask+="255"
        elif [ $i -eq $full_octets ]; then
            mask+=$(( 256 - 2**(8 - partial_octet) ))
        else
            mask+="0"
        fi
        [ $i -lt 3 ] && mask+="."
    done
    echo "$mask"
}

get_adapter_title() {
    local iface=$1
    if [ "$iface" = "lo" ]; then
        echo "Loopback adapter Local Loopback"
    elif [[ "$iface" =~ ^wl ]]; then
        echo "Wireless LAN adapter Wi-Fi ($iface)"
    elif [[ "$iface" =~ ^(en|eth) ]]; then
        echo "Ethernet adapter Ethernet ($iface)"
    elif [[ "$iface" =~ ^(docker|br-|virbr|veth) ]]; then
        echo "Virtual adapter ($iface)"
    else
        echo "Unknown adapter ($iface)"
    fi
}

# ----------------- Windows IP Configuration Header -----------------
HOSTNAME=$(hostname)
DNS_SUFFIX=$(dnsdomainname 2>/dev/null || hostname -d 2>/dev/null)
IP_ROUTING=$(sysctl -n net.ipv4.ip_forward 2>/dev/null | sed 's/1/Yes/;s/0/No/')
[ -z "$IP_ROUTING" ] && IP_ROUTING="No"

echo "Windows IP Configuration"
echo ""
echo "   Host Name . . . . . . . . . . . . : $HOSTNAME"
echo "   Primary Dns Suffix  . . . . . . . : $DNS_SUFFIX"
echo "   Node Type . . . . . . . . . . . . : Hybrid"
echo "   IP Routing Enabled. . . . . . . . : $IP_ROUTING"
echo "   WINS Proxy Enabled. . . . . . . . : No"
echo ""

# ----------------- Loop Through All Interfaces -----------------
# Get all interfaces present in /sys/class/net
INTERFACES=($(ip -o link show | awk -F': ' '{print $2}'))

for IFACE in "${INTERFACES[@]}"; do
    ADAPTER_TITLE=$(get_adapter_title "$IFACE")
    
    # Check link state
    OPERSTATE=$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)
    CARRIER=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)
    
    # Hardware description via udev or lspci/lsusb
    DESC=""
    if [ "$IFACE" = "lo" ]; then
        DESC="Software Loopback Interface 1"
    else
        # Try getting device name from NetworkManager or sysfs
        DESC=$(nmcli -t -f DEVICE,VENDOR,PRODUCT device show "$IFACE" 2>/dev/null | awk -F':' 'NR>1 && $2!="" {print $2}' | tr '\n' ' ' | sed 's/[ \t]*$//')
        if [ -z "$DESC" ]; then
            BUS_INFO=$(ethtool -i "$IFACE" 2>/dev/null | awk '/bus-info:/ {print $2}')
            [ -n "$BUS_INFO" ] && DESC=$(lspci -s "$BUS_INFO" 2>/dev/null | cut -d ':' -f 3 | sed 's/^[ \t]*//')
        fi
        [ -z "$DESC" ] && DESC="Ethernet or Virtual Device"
    fi

    # MAC / Physical Address
    MAC=$(ip link show dev "$IFACE" | awk '/link\/(ether|loopback)/ {print toupper($2)}' | tr ':' '-')
    [ -z "$MAC" ] && MAC="00-00-00-00-00-00"

    echo "$ADAPTER_TITLE:"
    echo ""
    echo "   Connection-specific DNS Suffix  . : "
    echo "   Description . . . . . . . . . . . : $DESC"
    echo "   Physical Address. . . . . . . . . : $MAC"

    # If the interface has no carrier / cable disconnected
    if [ "$OPERSTATE" = "down" ] || [ "$CARRIER" = "0" ]; then
        echo "   Media State . . . . . . . . . . . : Media disconnected"
        echo ""
        continue
    fi

    # DHCP Enabled check via nmcli
    DHCP_STATUS=$(nmcli -t -f IP4.NAME device show "$IFACE" 2>/dev/null | grep -q "DHCP4" && echo "Yes" || echo "No")
    echo "   DHCP Enabled. . . . . . . . . . . : $DHCP_STATUS"
    echo "   Autoconfiguration Enabled . . . . : Yes"

    # IPv6 Addresses
    IPV6_LINK=$(ip -6 addr show dev "$IFACE" scope link 2>/dev/null | awk '/inet6/ {print $2}' | cut -d '/' -f 1 | head -n 1)
    [ -n "$IPV6_LINK" ] && echo "   Link-local IPv6 Address . . . . . : ${IPV6_LINK}%${IFACE}(Preferred)"

    # IPv4 and Subnet
    IPV4_INFO=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -n 1)
    if [ -n "$IPV4_INFO" ]; then
        IPV4="${IPV4_INFO%/*}"
        CIDR="${IPV4_INFO#*/}"
        SUBNET=$(cidr_to_mask "$CIDR")
        echo "   IPv4 Address. . . . . . . . . . . : ${IPV4}(Preferred)"
        echo "   Subnet Mask . . . . . . . . . . . : $SUBNET"
    fi

    # Default Gateway
    GATEWAY=$(ip route show default dev "$IFACE" 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
    [ -n "$GATEWAY" ] && echo "   Default Gateway . . . . . . . . . : $GATEWAY"

    # DHCP Server
    DHCP_SRV=$(nmcli -f DHCP4.OPTION device show "$IFACE" 2>/dev/null | awk -F'= ' '/dhcp_server_identifier/ {print $2}')
    [ -n "$DHCP_SRV" ] && echo "   DHCP Server . . . . . . . . . . . : $DHCP_SRV"

    # DNS Servers
    mapfile -t DNS_SERVERS < <(nmcli -f IP4.DNS device show "$IFACE" 2>/dev/null | awk '{print $2}')
    if [ ${#DNS_SERVERS[@]} -gt 0 ]; then
        echo "   DNS Servers . . . . . . . . . . . : ${DNS_SERVERS[0]}"
        for ((i=1; i<${#DNS_SERVERS[@]}; i++)); do
            printf "                                       %s\n" "${DNS_SERVERS[$i]}"
        done
    fi

    echo ""
done
