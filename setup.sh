#!/bin/bash
# pwRFi Ultimate Installer for Raspberry Pi 5

# 1. Force Root
if [[ $EUID -ne 0 ]]; then
   echo "Please run with sudo: curl -sL [URL] | sudo bash"
   exit 1
fi

# 2. System Prep & Fix Locks
echo "Preparing System..."
killall apt apt-get 2>/dev/null
rm /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock 2>/dev/null
apt update -y
apt install -y python3-flask python3-bcrypt network-manager dnsmasq bc iptables-persistent

# 3. Enable IP Forwarding (The Internet Bridge)
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-pwrfi.conf

# 4. User Inputs
read -p "Admin Dashboard PW: " admin_pw
read -p "SSID (e.g. DSSWFN): " net_ssid
read -p "WiFi Password: " net_pass

# 5. Build Directories
USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)
mkdir -p /etc/pwrfi
mkdir -p "$USER_HOME/pwrfi_system"

# 6. Generate Config (Clean Python)
python3 << PY_EOF
import bcrypt, json
hashed = bcrypt.hashpw('$admin_pw'.encode(), bcrypt.gensalt()).decode()
with open('/etc/pwrfi/config.json', 'w') as f:
    json.dump({'admin_password': hashed, 'ssid': '$net_ssid', 'net_pass': '$net_pass'}, f)
PY_EOF

# 7. Create the Flask Dashboard
cat << 'FLASK_EOF' > "$USER_HOME/pwrfi_system/app.py"
from flask import Flask, request, session, redirect
import json, bcrypt, subprocess, os
app = Flask(__name__)
app.secret_key = os.urandom(24)

@app.route('/admin', methods=['GET', 'POST'])
def admin():
    with open("/etc/pwrfi/config.json", 'r') as f: cfg = json.load(f)
    if request.method == 'POST':
        if bcrypt.checkpw(request.form['pw'].encode(), cfg['admin_password'].encode()):
            session['admin'] = True
    if not session.get('admin'):
        return '<form method="post">PW: <input type="password" name="pw"><input type="submit"></form>'
    clients = subprocess.check_output(["nmcli", "-t", "-f", "IP4.ADDRESS,DEVICE,STATE", "device", "show"]).decode()
    return f"<h1>pwRFi Active</h1><pre>{clients}</pre>"

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80)
FLASK_EOF

# 8. Setup WiFi Hotspot
nmcli con delete pwRFi 2>/dev/null
nmcli con add type wifi ifname wlan0 mode ap con-name pwRFi ssid "$net_ssid" autoconnect yes \
802-11-wireless.band bg 802-11-wireless.channel 7 ipv4.method shared \
wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$net_pass"

# 9. Force NAT Routing
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save > /etc/iptables/rules.v4

# 10. Start Dashboard
nmcli con up pwRFi
python3 "$USER_HOME/pwrfi_system/app.py" &

echo "SUCCESS. Connect to $net_ssid and go to http://$(hostname -I | awk '{print $1}')/admin"
