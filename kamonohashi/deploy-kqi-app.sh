#!/bin/bash

readonly SCRIPT_DIR=$(cd $(dirname $0); pwd)

show_help() {
    echo "available args: prepare, deploy, clean, update, credentials, upgrade, help"
}

set_credentials(){
    kubectl apply -f kqi-namespace.yml
    # パスワードが未指定のものは、既にSecretに設定されているパスワードを設定する
    if [ -z "$PASSWORD" ]; then
      PASSWORD=$(kubectl get secret --namespace kqi-system platypus-web-api-env-secret -o jsonpath="{.data.DeployOptions__Password}" | base64 --decode)
    fi
    if [ -z "$DB_PASSWORD" ]; then
      DB_PASSWORD=$(kubectl get secret --namespace kqi-system postgres-credential -o jsonpath="{.data.POSTGRES_PASSWORD}" | base64 --decode)
    fi
    if [ -z "$STORAGE_PASSWORD" ]; then
      STORAGE_PASSWORD=$(kubectl get secret --namespace kqi-system minio-credential -o jsonpath="{.data.MINIO_ROOT_PASSWORD}" | base64 --decode)
      # MinIOが以前のバージョンだと環境変数名は"MINIO_SECRET_KEY"なので、そこからパスワードを取得する
      if [ -z "$STORAGE_PASSWORD" ]; then
        STORAGE_PASSWORD=$(kubectl get secret --namespace kqi-system minio-credential -o jsonpath="{.data.MINIO_SECRET_KEY}" | base64 --decode)
      fi
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
    helm delete --namespace kqi-system kamonohashi
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
