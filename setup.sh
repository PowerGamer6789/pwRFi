cat << 'EOF' | tee setup_pwrfi.sh > /dev/null
#!/bin/bash
progress_bar() {
    local duration=$1
    local label=$2
    echo -n "$label "
    for ((i=0; i<=20; i++)); do
        echo -n "█"
        sleep $(echo "scale=2; $duration / 20" | bc)
    done
    echo " Done!"
}
if ! ip link show eth0 | grep -q "state UP"; then
    echo -e "\e[31m[WARNING]\e[0m It seems you are not plugged into Ethernet."
    read -p "Starting pwRFi will result in SSH failing. Are you sure? (y/N): " confirm_ssh
    if [[ ! $confirm_ssh =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
sudo apt update -y > /dev/null 2>&1
sudo apt install -y python3-flask python3-bcrypt network-manager bc > /dev/null 2>&1
progress_bar 2 "Unpacking Binaries"
read -p "Set Admin Dashboard Password: " admin_pw
read -p "Set Network SSID (e.g. DSSWFN): " net_ssid
read -p "Set Network Username: " net_user
read -p "Set Network Password: " net_pass
sudo mkdir -p /etc/pwrfi
mkdir -p ~/pwrfi_system
sudo chown $USER:$USER /etc/pwrfi
progress_bar 1 "Building File Structure"
python3 -c "import bcrypt, json; hashed = bcrypt.hashpw('$admin_pw'.encode(), bcrypt.gensalt()).decode(); data = {'admin_password': hashed, 'ssid': '$net_ssid', 'net_user': '$net_user', 'net_pass': '$net_pass'}; with open('/etc/pwrfi/config.json', 'w') as f: json.dump(data, f)"
cat << 'INNER_EOF' | sudo tee /usr/local/bin/pwrfi > /dev/null
#!/usr/bin/env python3
import sys, json, bcrypt, os, subprocess
CONFIG_PATH = "/etc/pwrfi/config.json"
def load_cfg():
    with open(CONFIG_PATH, 'r') as f: return json.load(f)
def save_cfg(data):
    with open(CONFIG_PATH, 'w') as f: json.dump(data, f)
def sync_nm():
    c = load_cfg()
    subprocess.run(["sudo", "nmcli", "con", "modify", "pwRFi", "ssid", c['ssid'], "802-1x.identity", c['net_user'], "802-1x.password", c['net_pass']])
    subprocess.run(["sudo", "nmcli", "con", "up", "pwRFi"])
if len(sys.argv) < 2:
    sys.exit(1)
cmd = sys.argv[1]
if cmd == "setlogin":
    sub = sys.argv[2]
    cfg = load_cfg()
    if sub == "admin":
        cfg['admin_password'] = bcrypt.hashpw(sys.argv[3].encode(), bcrypt.gensalt()).decode()
    elif sub == "network":
        cfg['net_user'], cfg['net_pass'] = sys.argv[3], sys.argv[4]
        save_cfg(cfg)
        sync_nm()
    save_cfg(cfg)
elif cmd == "editnetwork":
    if sys.argv[2] == "ssid":
        cfg = load_cfg()
        cfg['ssid'] = sys.argv[3]
        save_cfg(cfg)
        sync_nm()
elif cmd == "run":
    subprocess.run(["sudo", "python3", os.path.expanduser("~/pwrfi_system/app.py")])
elif cmd == "uninstall":
    confirm = input("Wipe? (y/n): ")
    if confirm.lower() == 'y':
        os.system("sudo nmcli con delete pwRFi && sudo rm -rf /etc/pwrfi /usr/local/bin/pwrfi ~/pwrfi_system")
INNER_EOF
sudo chmod +x /usr/local/bin/pwrfi
cat << 'INNER_EOF' | tee ~/pwrfi_system/app.py > /dev/null
from flask import Flask, request, session, redirect
import json, bcrypt, subprocess, os
app = Flask(__name__)
app.secret_key = os.urandom(24)
@app.route('/admin', methods=['GET', 'POST'])
def admin():
    try:
        with open("/etc/pwrfi/config.json", 'r') as f: cfg = json.load(f)
    except: return "Error"
    if request.method == 'POST':
        if bcrypt.checkpw(request.form['pw'].encode(), cfg['admin_password'].encode()):
            session['admin'] = True
    if not session.get('admin'):
        return '<h2>pwRFi Login</h2><form method="post"><input type="password" name="pw"><input type="submit"></form>'
    clients = subprocess.check_output(["nmcli", "-t", "-f", "IP4.ADDRESS,DEVICE,STATE", "device", "show"]).decode()
    return f"<h1>pwRFi</h1><pre>{clients}</pre><br><a href='/logout'>Logout</a>"
@app.route('/logout')
def logout():
    session.clear()
    return redirect('/admin')
if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80)
INNER_EOF
progress_bar 2 "Broadcasting"
sudo nmcli con delete pwRFi 2>/dev/null
sudo nmcli con add type wifi ifname wlan0 mode ap con-name pwRFi ssid "$net_ssid" autoconnect yes 802-11-wireless.band bg 802-11-wireless.channel 7 ipv4.method shared 802-11-wireless-security.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2 802-1x.identity "$net_user" 802-1x.password "$net_pass"
sudo nmcli con up pwRFi
read -p "Auto-start on boot? (y/N): " auto_start
if [[ $auto_start =~ ^[Yy]$ ]]; then
    (crontab -l 2>/dev/null; echo "@reboot sudo /usr/local/bin/pwrfi run &") | crontab -
fi
EOF
