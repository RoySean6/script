#!/bin/bash

# 函数：检查代理格式并拆分为组件
parse_proxy() {
    local proxy_url=$1
    if [[ $proxy_url =~ ^(https?)://([^:@]+):([^:@]+)@([^:/]+):([0-9]+)$ ]]; then
        PROXY_TYPE=${BASH_REMATCH[1]}
        PROXY_USER=${BASH_REMATCH[2]}
        PROXY_PASS=${BASH_REMATCH[3]}
        PROXY_HOST=${BASH_REMATCH[4]}
        PROXY_PORT=${BASH_REMATCH[5]}
    else
        echo "Proxy format is invalid."
        return 1
    fi
    return 0
}

# 检查并安装必要的软件
check_install() {
    local name=$1
    local command=$2
    local install_command=$3

    if ! command -v $command &> /dev/null
    then
        echo "Installing $name..."
        eval $install_command || { echo "Failed to install $name. Exiting."; exit 1; }
    else
        echo "$name is already installed."
    fi
}

add_new_configuration() {
    check_install "socat" "socat" "wget http://www.dest-unreach.org/socat/download/socat-1.7.4.4.tar.gz && tar xzf socat-1.7.4.4.tar.gz && cd socat-1.7.4.4 && ./configure && make && sudo make install && cd .. && rm -rf socat-1.7.4.4 socat-1.7.4.4.tar.gz"
    check_install "proxychains-ng" "proxychains4" "git clone https://github.com/rofl0r/proxychains-ng.git && cd proxychains-ng && ./configure --prefix=/usr --sysconfdir=/etc && make && sudo make install && cd .. && rm -rf proxychains-ng"
    check_install "supervisor" "supervisorctl" "sudo apt-get update && sudo apt-get install -y supervisor"

    echo "Enter proxy (format: https://user:password@host:port):"
    read proxy
    parse_proxy $proxy || { echo "Error parsing proxy details. Exiting."; return 1; }

    if ! curl -x $PROXY_TYPE://$PROXY_USER:$PROXY_PASS@$PROXY_HOST:$PROXY_PORT http://httpbin.org/get; then
        echo "Proxy is not working. Exiting."
        return 1
    fi
    echo "Proxy is working."

    echo "Enter local port:"
    read local_port
    echo "Enter target domain (with port if not 443):"
    read target_domain

    TARGET_HOST=$(echo $target_domain | cut -d':' -f1)
    TARGET_PORT=$(echo $target_domain | cut -s -d':' -f2)
    TARGET_PORT=${TARGET_PORT:-443}
    CERT_FILE="/root/${TARGET_HOST}.pem"

    if lsof -i :$local_port
    then
        echo "Port $local_port is already in use. Trying to free it..."
        sudo fuser -k $local_port/tcp
    fi

    cd /root
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$TARGET_HOST" -keyout $CERT_FILE -out $CERT_FILE

    PROXYCHAINS_CONF="/etc/proxychains_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1).conf"
    proxy_conf="socks5  $PROXY_HOST  $PROXY_PORT  $PROXY_USER  $PROXY_PASS"
    echo -e "[ProxyList]\n$proxy_conf" | sudo tee $PROXYCHAINS_CONF

    supervisor_program_name="$TARGET_HOST"
    supervisor_conf="[program:$supervisor_program_name]
    user=root
    command=proxychains4 -f $PROXYCHAINS_CONF socat OPENSSL-LISTEN:$local_port,reuseaddr,fork,verify=0,cert=$CERT_FILE OPENSSL:$TARGET_HOST:$TARGET_PORT,verify=0
    directory=/root
    autorestart=true
    startsecs=10
    startretries=100"

    sudo echo "$supervisor_conf" | sudo tee /etc/supervisor/conf.d/$supervisor_program_name.conf

    sudo supervisorctl update
    sudo supervisorctl restart $supervisor_program_name

    curl -k -v -H "Host: $TARGET_HOST" https://127.0.0.1:$local_port

    echo "New configuration added."
}

manage_existing_configurations() {
    echo "Existing supervisor configurations:"
    ls /etc/supervisor/conf.d/

    read -p "Enter the name of configuration to manage (or enter to cancel): " config_name
    if [ -z "$config_name" ]; then
        echo "No configuration selected. Exiting."
        exit 0
    fi

    if [ -f "/etc/supervisor/conf.d/$config_name.conf" ]; then
        echo "Selected configuration: $config_name"
        read -p "Do you want to delete this configuration? (y/n): " delete_choice
        if [ "$delete_choice" == "y" ]; then
            sudo rm "/etc/supervisor/conf.d/$config_name.conf"
            sudo supervisorctl reread
            sudo supervisorctl update
            echo "Configuration $config_name deleted."
        else
            echo "Configuration not deleted."
        fi
    else
        echo "Configuration $config_name not found."
    fi
}

check_configuration_status() {
    echo "Existing supervisor configurations:"
    ls /etc/supervisor/conf.d/

    read -p "Enter the domain name of the configuration to check (or enter to cancel): " config_domain
    if [ -z "$config_domain" ]; then
        echo "No configuration selected. Exiting."
        exit 0
    fi

    if [ -f "/etc/supervisor/conf.d/$config_domain.conf" ]; then
        echo "Selected configuration: $config_domain"
        CONFIG_PORT=$(grep "OPENSSL-LISTEN" /etc/supervisor/conf.d/$config_domain.conf | sed -n 's/.*OPENSSL-LISTEN:\([0-9]*\).*/\1/p')
        if [ -n "$CONFIG_PORT" ]; then
            curl -k -v -H "Host: $config_domain" https://127.0.0.1:$CONFIG_PORT
        else
            echo "Could not determine the port for $config_domain."
        fi
    else
        echo "Configuration $config_domain not found."
    fi
}

echo "Choose an option:"
echo "1) Add new configuration"
echo "2) Show and manage existing configurations"
echo "3) Check configuration status"
read -p "Enter your choice (1-3): " choice

case $choice in
    1)
        add_new_configuration
        ;;
    2)
        manage_existing_configurations
        ;;
    3)
        check_configuration_status
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
