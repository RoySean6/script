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
        exit 1
    fi
}

# 检查并安装必要的软件
check_install() {
    local name=$1
    local command=$2
    local install_command=$3

    if ! command -v $command &> /dev/null
    then
        echo "Installing $name..."
        eval $install_command
    else
        echo "$name is already installed."
    fi
}

check_install "socat" "socat" "wget http://www.dest-unreach.org/socat/download/socat-1.7.4.4.tar.gz && tar xzf socat-1.7.4.4.tar.gz && cd socat-1.7.4.4 && ./configure && make && sudo make install && cd .. && rm -rf socat-1.7.4.4 socat-1.7.4.4.tar.gz"
check_install "proxychains-ng" "proxychains4" "git clone https://github.com/rofl0r/proxychains-ng.git && cd proxychains-ng && ./configure --prefix=/usr --sysconfdir=/etc && make && sudo make install && cd .. && rm -rf proxychains-ng"
check_install "supervisor" "supervisorctl" "sudo apt-get update && sudo apt-get install -y supervisor"

# 获取并解析代理信息
echo "Enter proxy (format: https://user:password@host:port):"
read proxy
parse_proxy $proxy

# 检测代理是否可用
if curl -x $PROXY_TYPE://$PROXY_USER:$PROXY_PASS@$PROXY_HOST:$PROXY_PORT cip.cc; then
    echo "Proxy is working."
else
    echo "Proxy is not working."
    exit 1
fi

# 获取本地端口和目标域名
echo "Enter local port:"
read local_port
echo "Enter target domain (optionally with port, default is 443):"
read target_domain

# 如果目标域名不包含端口，则默认为443
TARGET_HOST=$(echo $target_domain | cut -d':' -f1)
TARGET_PORT=$(echo $target_domain | cut -s -d':' -f2)
TARGET_PORT=${TARGET_PORT:-443}

# 检查端口是否被占用
if lsof -i :$local_port
then
    echo "Port $local_port is already in use. Trying to free it..."
    sudo fuser -k $local_port/tcp
fi

# 创建一个随机的proxychains配置文件名
PROXYCHAINS_CONF="/etc/proxychains_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1).conf"
proxy_conf="socks5  $PROXY_HOST  $PROXY_PORT  $PROXY_USER  $PROXY_PASS"
echo -e "[ProxyList]\n$proxy_conf" | sudo tee $PROXYCHAINS_CONF

# 配置supervisor
supervisor_program_name=$(echo $TARGET_HOST | cut -d'.' -f1)
supervisor_conf="[program:$supervisor_program_name]
user=root
command=proxychains4 -f $PROXYCHAINS_CONF socat OPENSSL-LISTEN:$local_port,reuseaddr,fork,verify=0,cert=server.pem OPENSSL:$TARGET_HOST:$TARGET_PORT,verify=0
directory=/root
autorestart=true
startsecs=10
startretries=100"

sudo echo "$supervisor_conf" | sudo tee /etc/supervisor/conf.d/$supervisor_program_name.conf

# 更新并重启特定的supervisor配置
sudo supervisorctl update
sudo supervisorctl restart $supervisor_program_name

echo "Checking if the socat service is working..."
curl -k -v -H "Host: $TARGET_HOST" https://127.0.0.1:$local_port

echo "Setup complete."
