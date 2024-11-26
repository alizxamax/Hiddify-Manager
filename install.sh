#!/bin/bash
cd $(dirname -- "$0")
source ./common/utils.sh
NAME="0-install"
LOG_FILE="$(log_file $NAME)"

# Detect if the OS is Alpine Linux
if grep -q "ID=alpine" /etc/os-release; then
    IS_ALPINE=true
else
    IS_ALPINE=false
fi

# Fix the installation directory
if [ ! -d "/opt/hiddify-manager/" ] && [ -d "/opt/hiddify-server/" ]; then
    mv /opt/hiddify-server /opt/hiddify-manager
    ln -s /opt/hiddify-manager /opt/hiddify-server
fi
if [ ! -d "/opt/hiddify-manager/" ] && [ -d "/opt/hiddify-config/" ]; then
    mv /opt/hiddify-config/ /opt/hiddify-manager/
    ln -s /opt/hiddify-manager /opt/hiddify-config
fi

export DEBIAN_FRONTEND=noninteractive
if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run by root' >&2
    exit 1
fi

function install_dependencies_alpine() {
    echo "Installing dependencies for Alpine Linux..."
    apk update
    apk add --no-cache bash curl python3 py3-pip openssl redis mysql-client nginx haproxy
    ln -sf /usr/bin/python3 /usr/bin/python
    pip3 install --upgrade pip
}

function install_python() {
    if $IS_ALPINE; then
        install_dependencies_alpine
    else
        apt-get update && apt-get install -y python3 python3-pip
        ln -sf /usr/bin/python3 /usr/bin/python
        pip3 install --upgrade pip
    fi
}

function activate_python_venv() {
    python3 -m venv /opt/hiddify-manager/venv
    source /opt/hiddify-manager/venv/bin/activate
    pip install -r requirements.txt
}

function main() {
    update_progress "Please wait..." "We are going to install Hiddify..." 0
    export ERROR=0
    
    export PROGRESS_ACTION="Installing..."
    if [ "$MODE" == "apply_users" ]; then
        export DO_NOT_INSTALL="true"
    elif [ -d "/hiddify-data-default/" ] && [ -z "$(ls -A /hiddify-data/ 2>/dev/null)" ]; then
        cp -r /hiddify-data-default/* /hiddify-data/
    fi
    if [ "$DO_NOT_INSTALL" == "true" ]; then
        PROGRESS_ACTION="Applying..."
    fi
    if [ "$HIDDIFY_DEBUG" = "1" ]; then
        export USE_VENV=true
    fi
    
    install_python
    activate_python_venv
    
    if [ "$MODE" != "apply_users" ]; then
        clean_files
        update_progress "${PROGRESS_ACTION}" "Common Tools and Requirements" 2
        runsh install.sh common
        if [ "${DOCKER_MODE}" != "true" ]; then
            install_run other/redis
            install_run other/mysql
        fi

        install_run hiddify-panel
    fi
    
    update_progress "HiddifyPanel" "Reading Configs from Panel..." 5
    set_config_from_hpanel
    
    update_progress "Applying Configs" "..." 8
    
    bash common/replace_variables.sh
    
    if [ "$MODE" != "apply_users" ]; then
        bash ./other/deprecated/remove_deprecated.sh
        update_progress "Configuring..." "System and Firewall settings" 10
        runsh run.sh common
        
        update_progress "${PROGRESS_ACTION}" "Nginx" 15
        install_run nginx
        
        update_progress "${PROGRESS_ACTION}" "Haproxy for Splitting Traffic" 20
        install_run haproxy
        
        update_progress "${PROGRESS_ACTION}" "Getting Certificates" 30
        install_run acme.sh
        
        update_progress "${PROGRESS_ACTION}" "Personal SpeedTest" 35
        install_run other/speedtest $(hconfig "speed_test")
        
        update_progress "${PROGRESS_ACTION}" "Telegram Proxy" 40
        install_run other/telegram $(hconfig "telegram_enable")
        
        update_progress "${PROGRESS_ACTION}" "FakeTLS Proxy" 45
        install_run other/ssfaketls $(hconfig "ssfaketls_enable")
        
        update_progress "${PROGRESS_ACTION}" "SSH Proxy" 55
        install_run other/ssh $(hconfig "ssh_server_enable")
        
        update_progress "${PROGRESS_ACTION}" "Xray" 70
        if [[ $(hconfig "core_type") == "xray" ]]; then
            install_run xray 1
        else
            install_run xray 0
        fi
        
        update_progress "${PROGRESS_ACTION}" "Warp" 75
        if [[ $(hconfig "warp_mode") != "disable" ]]; then
            install_run other/warp 1
        else   
            install_run other/warp 0
        fi
        
        update_progress "${PROGRESS_ACTION}" "HiddifyCli" 90
        install_run other/hiddify-cli $(hconfig "hiddifycli_enable")
    fi
    
    update_progress "${PROGRESS_ACTION}" "Wireguard" 85
    install_run other/wireguard $(hconfig "wireguard_enable")
    
    update_progress "${PROGRESS_ACTION}" "Singbox" 95
    install_run singbox
    
    update_progress "${PROGRESS_ACTION}" "Almost Finished" 98
    
    echo "---------------------Finished!------------------------"
    remove_lock $NAME
    if [ "$MODE" != "apply_users" ]; then
        if $IS_ALPINE; then
            rc-service hiddify-panel stop
        else
            systemctl stop hiddify-panel
        fi
    fi
    if $IS_ALPINE; then
        rc-service hiddify-panel start
    else
        systemctl start hiddify-panel
    fi
    update_progress "${PROGRESS_ACTION}" "Done" 100
}

# Rest of the script remains unchanged
