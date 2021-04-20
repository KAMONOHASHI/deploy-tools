#!/bin/bash

readonly SCRIPT_DIR=$(cd $(dirname $0); pwd)

show_help() {
    echo "available args: prepare, deploy, clean, update, credentials, upgrade, help"
}


set_credentials(){   
    kubectl apply -f kqi-namespace.yml
    if [ -z "$PASSWORD" ] || [ -z "$DB_PASSWORD" ] || [ -z "$STORAGE_PASSWORD" ]; then
      echo -en "\e[33mAdmin Passwordを入力: \e[m"; read -s PASSWORD
      echo -en "\n\e[33mDB Passwordを入力: \e[m"; read -s DB_PASSWORD
      echo -en "\n\e[33mStorage Secret Keyを入力: \e[m"; read -s STORAGE_PASSWORD
      echo "" # read -sは改行しないので改行 
    fi  
    SET_ARGS="password=$PASSWORD,db_password=$DB_PASSWORD,storage_secretkey=$STORAGE_PASSWORD"
    helm upgrade kamonohashi-credentials charts/kamonohashi-credentials -i --set $SET_ARGS --namespace kqi-system
}

deploy(){
    kubectl apply -f kqi-namespace.yml
    helm upgrade kamonohashi charts/kamonohashi -f conf/settings.yml -i --namespace kqi-system --wait
}

update(){
    helm upgrade \
      -i kamonohashi charts/kamonohashi \
      -f conf/settings.yml \
      --namespace kqi-system \
      --wait
}

clean(){
    helm delete --purge kamonohashi
}

main(){
  cd $SCRIPT_DIR
  case $1 in
    prepare) prepare ;;
    deploy) deploy ;;
    update) update;;
    credentials) set_credentials;;
    clean) clean ;;
    help) show_help ;;
    *) show_help ;;
  esac
}

main $@
