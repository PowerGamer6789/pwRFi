#!/bin/bash
# pwRFi Final - Raspberry Pi 5 Optimized

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo."
   exit 1
fi

# 1. Environment & Dependencies
apt update -y && apt install -y python3-flask python3-bcrypt network-manager iptables-persistent bc
mkdir -p /etc/pwrfi /home/pwr/pwrfi_system

# 2. Initial Setup Inputs
read -p "Initial Admin Password: " admin_pw
read -p "Initial Network SSID: " net_ssid
read -p "Initial Network Password: " net_pass

# Save initial credentials
python3 -c "import bcrypt; print(bcrypt.hashpw('$admin_pw'.encode(), bcrypt.gensalt()).decode())" > /etc/pwrfi/pw.hash
echo "{\"ssid\": \"$net_ssid\", \"pass\": \"$net_pass\"}" > /etc/pwrfi/config.json

# 3. Create the 'pwrfi' CLI with your specific commands
cat << 'EOF' > /usr/local/bin/pwrfi
#!/bin/bash

case "$1" in
    devices)
        echo -e "\n--- pwRFi Connected Devices ---"
        printf "%-20s %-15s %-20s\n" "HOSTNAME" "IP" "MAC"
        awk '{printf "%-20s %-15s %-20s\n", $4, $3, $2}' /var/lib/NetworkManager/internal-dnsmasq-wlan0.leases 2>/dev/null || echo "No active leases."
        ;;
    setlogin)
        if [ "$2" == "network" ]; then
            NEW_PASS=$3
            if [ -z "$NEW_PASS" ]; then echo "Usage: pwrfi setlogin network <password>"; exit 1; fi
            sudo nmcli con modify pwRFi wifi-sec.psk "$NEW_PASS"
            sudo nmcli con up pwRFi
            echo "Network password updated and hotspot restarted."
        elif [ "$2" == "admin" ]; then
            NEW_ADMIN=$3
            if [ -z "$NEW_ADMIN" ]; then echo "Usage: pwrfi setlogin admin <password>"; exit 1; fi
            python3 -c "import bcrypt; print(bcrypt.hashpw('$NEW_ADMIN'.encode(), bcrypt.gensalt()).decode())" > /etc/pwrfi/pw.hash
            echo "Admin dashboard password updated."
        else
            echo "Usage: pwrfi setlogin [network|admin] <password>"
        fi
        ;;
    restart)
        echo "Restarting pwRFi Services..."
        sudo nmcli con down pwRFi && sudo nmcli con up pwRFi
        sudo fuser -k 80/tcp 2>/dev/null
        nohup python3 /home/pwr/pwrfi_system/app.py > /dev/null 2>&1 &
        echo "Done."
        ;;
    uninstall)
        echo "Reverting system changes..."
        sudo nmcli con delete pwRFi 2>/dev/null
        sudo rm -rf /etc/pwrfi /home/pwr/pwrfi_system /usr/local/bin/pwrfi
        echo "pwRFi has been removed."
        ;;
    *)
        echo "Usage: pwrfi [devices|setlogin|restart|uninstall]"
        ;;
esac
EOF
chmod +x /usr/local/bin/pwrfi

# 4. Networking Config (Bridge)
sysctl -w net.ipv4.ip_forward=1
systemctl stop dnsmasq 2>/dev/null
systemctl disable dnsmasq 2>/dev/null

nmcli con delete pwRFi 2>/dev/null
nmcli con add type wifi ifname wlan0 mode ap con-name pwRFi ssid "$net_ssid" \
ipv4.method shared wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$net_pass"
nmcli con up pwRFi

# 5. Dashboard Setup
cat << 'EOF' > /home/pwr/pwrfi_system/app.py
from flask import Flask, request, session, redirect
import json, bcrypt, subprocess, os
app = Flask(__name__)
app.secret_key = os.urandom(24)

@app.route('/admin', methods=['GET', 'POST'])
def admin():
    if request.method == 'POST':
        with open("/etc/pwrfi/pw.hash", 'r') as f: h = f.read().strip()
        if bcrypt.checkpw(request.form.get('pw', '').encode(), h.encode()):
            session['in'] = True
            return "<h1>Logged In</h1><p>Use 'pwrfi devices' in terminal for now.</p>"
    return '<form method="post">PW: <input type="password" name="pw"><input type="submit"></form>'

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80)
EOF

# Start Web App
nohup python3 /home/pwr/pwrfi_system/app.py > /dev/null 2>&1 &

echo "--- SETUP COMPLETE ---"
