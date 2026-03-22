cat << 'EOF' | tee setup_pwrfi.sh > /dev/null
#!/bin/bash

# 1. Colors and Progress
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

progress_bar() {
    local duration=$1
    local label=$2
    echo -n "$label "
    for ((i=0; i<=20; i++)); do
        echo -n "█"
        sleep $(echo "scale=2; $duration / 20" | bc)
    done
    echo -e " ${GREEN}Done!${NC}"
}

# 2. Pre-flight Checks
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR]${NC} This script must be run with sudo."
   exit 1
fi

if ! ip link show eth0 | grep -q "state UP"; then
    echo -e "${RED}[WARNING]${NC} eth0 (Ethernet) is down. DSSWFN will have No Internet."
    read -p "Continue anyway? (y/N): " confirm_eth
    [[ ! $confirm_eth =~ ^[Yy]$ ]] && exit 1
fi

# 3. Dependencies & Routing Config
echo "Installing System Dependencies..."
apt update -y > /dev/null 2>&1
apt install -y python3-flask python3-bcrypt network-manager dnsmasq bc iptables-persistent > /dev/null 2>&1

# Enable IPv4 Forwarding (The "No Internet" Fix)
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | tee /etc/sysctl.d/99-pwrfi.conf > /dev/null

# Set up NAT Masquerade
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# Save rules for reboot
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt install -y iptables-persistent > /dev/null 2>&1

progress_bar 1 "Optimizing Network Stack"

# 4. User Configuration
read -p "Set Admin Dashboard Password: " admin_pw
read -p "Set Network SSID (e.g. DSSWFN): " net_ssid
read -p "Set Network Password (min 8 chars): " net_pass

mkdir -p /etc/pwrfi
mkdir -p /home/$SUDO_USER/pwrfi_system
chown $SUDO_USER:$SUDO_USER /etc/pwrfi /home/$SUDO_USER/pwrfi_system

# 5. Generate Config (Safe Python Method)
python3 << PY_EOF
import bcrypt, json
hashed = bcrypt.hashpw('$admin_pw'.encode(), bcrypt.gensalt()).decode()
data = {'admin_password': hashed, 'ssid': '$net_ssid', 'net_pass': '$net_pass'}
with open('/etc/pwrfi/config.json', 'w') as f:
    json.dump(data, f)
PY_EOF

# 6. Create the pwrfi CLI Tool
cat << 'INNER_EOF' | tee /usr/local/bin/pwrfi > /dev/null
#!/usr/bin/env python3
import sys, json, bcrypt, os, subprocess
CONFIG_PATH = "/etc/pwrfi/config.json"

def load_cfg():
    with open(CONFIG_PATH, 'r') as f: return json.load(f)

def sync_nm():
    c = load_cfg()
    subprocess.run(["sudo", "nmcli", "con", "modify", "pwRFi", "ssid", c['ssid'], "wifi-sec.psk", c['net_pass']])
    subprocess.run(["sudo", "nmcli", "con", "up", "pwRFi"])

if len(sys.argv) < 2: sys.exit(1)
cmd = sys.argv[1]

if cmd == "run":
    # Get the real user's home dir for app.py
    home_dir = os.path.expanduser("~")
    subprocess.run(["python3", f"{home_dir}/pwrfi_system/app.py"])
elif cmd == "uninstall":
    if input("Wipe everything? (y/n): ").lower() == 'y':
        os.system("nmcli con delete pwRFi && rm -rf /etc/pwrfi /usr/local/bin/pwrfi")
INNER_EOF

chmod +x /usr/local/bin/pwrfi

# 7. Create Flask Dashboard
cat << 'INNER_EOF' | tee /home/$SUDO_USER/pwrfi_system/app.py > /dev/null
from flask import Flask, request, session, redirect
import json, bcrypt, subprocess, os
app = Flask(__name__)
app.secret_key = os.urandom(24)

@app.route('/admin', methods=['GET', 'POST'])
def admin():
    try:
        with open("/etc/pwrfi/config.json", 'r') as f: cfg = json.load(f)
    except: return "Configuration file missing."
    
    if request.method == 'POST':
        if bcrypt.checkpw(request.form['pw'].encode(), cfg['admin_password'].encode()):
            session['admin'] = True
    
    if not session.get('admin'):
        return '<h2>pwRFi Dashboard</h2><form method="post"><input type="password" name="pw"><input type="submit" value="Login"></form>'
    
    clients = subprocess.check_output(["nmcli", "-t", "-f", "IP4.ADDRESS,DEVICE,STATE", "device", "show"]).decode()
    return f"<h1>pwRFi Node: {cfg['ssid']}</h1><pre>{clients}</pre><br><a href='/logout'>Logout</a>"

@app.route('/logout')
def logout():
    session.clear()
    return redirect('/admin')

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80)
INNER_EOF

# 8. Broadcast the SSID
progress_bar 2 "Broadcasting DSSWFN"

nmcli con delete pwRFi 2>/dev/null
nmcli con add type wifi ifname wlan0 mode ap con-name pwRFi ssid "$net_ssid" autoconnect yes \
802-11-wireless.band bg 802-11-wireless.channel 7 \
ipv4.method shared \
wifi-sec.key-mgmt wpa-psk \
wifi-sec.psk "$net_pass"

nmcli con up pwRFi

# 9. Persistence
read -p "Auto-start Dashboard on boot? (y/N): " auto_start
if [[ $auto_start =~ ^[Yy]$ ]]; then
    (crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/pwrfi run &") | crontab -
fi

echo -e "${GREEN}SUCCESS!${NC} pwRFi is online."
echo "Connect to: $net_ssid"
echo "Admin Panel: http://$(hostname -I | awk '{print $1}')/admin"
EOF
