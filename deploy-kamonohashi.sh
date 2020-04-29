#!/bin/bash
readonly SCRIPT_DIR=$(cd $(dirname $0); pwd)
readonly GIT_TAG=$(cd $SCRIPT_DIR && git tag --points-at HEAD)
readonly GIT_HASH=$(cd $SCRIPT_DIR && git rev-parse HEAD)
readonly THIS_SCRIPT_VER=${GIT_TAG:-$GIT_HASH}

readonly LOG_DIR=/var/log/kamonohashi/deploy-tools
readonly LOG_FILE=$LOG_DIR/deploy_$(date '+%Y%m%d-%H%M%S').log

readonly HELP_URL="https://kamonohashi.ai/docs/install-and-update"

readonly DEEPOPS_DIR=$SCRIPT_DIR/deepops
readonly HELM_DIR=$SCRIPT_DIR/kamonohashi
readonly FILES_DIR=$SCRIPT_DIR/files

# deepopsの設定ファイル
readonly INFRA_CONF_DIR=$DEEPOPS_DIR/config
readonly INVENTORY=$INFRA_CONF_DIR/inventory
readonly GROUP_VARS_DIR=$INFRA_CONF_DIR/group_vars
readonly GROUP_VARS_ALL=$GROUP_VARS_DIR/all.yml
readonly GROUP_VARS_K8S=$GROUP_VARS_DIR/k8s-cluster.yml

# KAMONOHASHI Helmの設定ファイル
readonly APP_CONF_DIR=$HELM_DIR/conf
readonly APP_CONF_FILE=$APP_CONF_DIR/settings.yml

# 関数定義

ask_ssh_user(){
  echo -en "\e[33mSSHで利用するユーザー名: \e[m"; read SSH_USER
}

ask_cluster_node_conf(){
  echo -en "\e[33mKubernetes masterをデプロイするサーバ名: \e[m"; read KUBE_MASTER
  echo -en "\e[33mKAMONOHASHIをデプロイするサーバ名: \e[m"; read KQI_NODE
  echo -en "\e[33mStorageをデプロイするサーバ名: \e[m"; read STORAGE
  echo -en "\e[33m計算ノード名(,区切りで複数可): \e[m"; read COMPUTE_NODES_COMMA
}

# コマンド実行前にユーザーにdeepops側にプロキシ設定させ、それを読み込む
load_proxy_conf(){
  . $DEEPOPS_DIR/scripts/proxy.sh
}

ask_cluster_conf(){
  echo "クラスタの構成情報を入力してください"
  echo "詳細は ${HELP_URL} を参照してください"

  ask_cluster_node_conf
  ask_ssh_user
}

set_single_node_conf(){
  local HOST=$(hostname)
  KUBE_MASTER=$HOST
  KQI_NODE=$HOST
  STORAGE=$HOST
  COMPUTE_NODES_COMMA=$HOST
}

ask_single_node_conf(){
  echo "構成情報を入力してください"
  echo "詳細は ${HELP_URL} を参照してください"

  ask_ssh_user
  set_single_node_conf
}

get_ip(){
  local IP_BY_DNS=$(host $1 | awk '/has address/ { print $4 }')
  if [ -z "$IP_BY_DNS" ]; then
    # 名前解決した結果からループバックを除き先頭のIPを選択
    # hostコマンドはhostsを見ない。getentは/etc/nsswitch.confに従って解決する
    local IP=$(getent hosts $1 | awk '{print $1}' | grep -v ^127.* | head -1)
  else
    local IP=$IP_BY_DNS
  fi
  echo $IP
}

# no_proxyを正しく設定していなかった場合でも動くようにKAMONOHASHIでno_proxyを設定する
setup_no_proxy(){
  KUBE_MASTER_IP=$(get_ip $KUBE_MASTER)
  STORAGE_IP=$(get_ip $STORAGE)
  NO_PROXY_BASE=$KUBE_MASTER,$KUBE_MASTER_IP,$STORAGE,$STORAGE_IP,$COMPUTE_NODES_COMMA,$KQI_NODE,localhost,127.0.0.1,.local

  if [ ! -z "$no_proxy" ]; then
    no_proxy=$no_proxy,$NO_PROXY_BASE
  else
    no_proxy=$NO_PROXY_BASE
  fi  
  # 重複排除
  no_proxy=$(echo -n "$no_proxy" | awk 'BEGIN{RS=ORS=","} {sub(/ ..:..:..$/,"")} !seen[$0]++')
  #末尾の,削除
  export no_proxy=${no_proxy%,}
}

# 本来deepoposのsetup.shで設定されるはずだが、バグで設定されないので
# KAMONOHASHIで設定する。「http_proxyが存在するがhttps_proxyがない」ようなケースは想定しない
append_deepops_proxy_conf(){
cat <<EOF >> $GROUP_VARS_ALL

http_proxy: $http_proxy
https_proxy: $https_proxy
no_proxy: $no_proxy

proxy_env:
  http_proxy: $http_proxy
  https_proxy: $https_proxy
  no_proxy: $no_proxy
EOF
}

# 「http_proxyが存在するがhttps_proxyがない]」ようなケースは想定しない
append_proxy_helm_conf(){

cat <<EOF >> $APP_CONF_FILE

http_proxy: $http_proxy
https_proxy: $https_proxy
no_proxy: $no_proxy
EOF
}

generate_deepops_vars(){
  # backup_old_conf関数でバックアップが取得済み想定で、ファイルを初期化する。
  cp -f $FILES_DIR/deepops/all.yml $GROUP_VARS_ALL
  cp -f $FILES_DIR/deepops/nfs-server.yml $GROUP_VARS_DIR
  cp -f $FILES_DIR/deepops/k8s-cluster.yml $GROUP_VARS_K8S
  if [ ! -z "$https_proxy" ]; then
    append_deepops_proxy_conf
  fi
}

generate_deepops_inventory(){
  # ,区切り => 改行
  COMPUTE_NODES=$(echo -e "${COMPUTE_NODES_COMMA//,/\\n}")

  ALL_NODES=$(echo -e "${KUBE_MASTER}\n${KQI_NODE}\n${STORAGE}\n${COMPUTE_NODES}")  
  KUBE_NODES=$(echo -e "${KQI_NODE}\n${STORAGE}\n${COMPUTE_NODES}")  
  # 重複排除
  ALL_NODES=$( IFS=$'\n' ; echo "${ALL_NODES[*]}" | sort | uniq ) 
  KUBE_NODES=$( IFS=$'\n' ; echo "${KUBE_NODES[*]}" | sort | uniq ) 

  for HOST in $ALL_NODES
  do
    NODE_IP=$(get_ip $HOST)
    ALL=$(echo -e "$HOST ansible_host=$NODE_IP\n$ALL\n")
  done

  ALL=$ALL \
  KUBE_MASTER=$KUBE_MASTER \
  ETCD=$KUBE_MASTER \
  KUBE_NODES=$KUBE_NODES \
  NFS=$STORAGE \
  SSH_USER=$SSH_USER \
  envsubst < $FILES_DIR/deepops/inventory.template > $INVENTORY
}

generate_helm_conf(){
  KQI_NODE=$KQI_NODE \
  NODES=${COMPUTE_NODES_COMMA} \
  OBJECT_STORAGE=$STORAGE \
  OBJECT_STORAGE_PORT=9000 \
  OBJECT_STORAGE_ACCESSKEY=admin \
  NFS_STORAGE=$STORAGE \
  NFS_PATH=/var/lib/kamonohashi/nfs \
  envsubst < $FILES_DIR/kamonohashi-helm/settings.yml > $APP_CONF_FILE

  if [ ! -z "$https_proxy" ]; then
    append_proxy_helm_conf
  fi
}

backup_old_conf(){
  local SUFFIX=$(date +%Y%m%d)
  mkdir -p $INFRA_CONF_DIR/old/ $APP_CONF_DIR/old/
  # 「2>/dev/null || :」 は次を参照
  # https://serverfault.com/questions/153875/how-to-let-cp-command-dont-fire-an-error-when-source-file-does-not-exist
  cp $INVENTORY $INFRA_CONF_DIR/old/inventory.$SUFFIX 2>/dev/null || :
  cp -r $GROUP_VARS_DIR $INFRA_CONF_DIR/old/group_vars.$SUFFIX 2>/dev/null || :
  cp -r $APP_CONF_FILE $APP_CONF_DIR/old/settings.yml.$SUFFIX 2>/dev/null || :
}

generate_deepops_conf(){
  generate_deepops_inventory
  generate_deepops_vars
}

generate_conf(){
  backup_old_conf
  generate_deepops_conf
  generate_helm_conf
}

prepare_deepops(){
  cd $DEEPOPS_DIR
  ./scripts/setup.sh
}

# prepareでは設定ディレクトリのみ用意
prepare_helm(){
  mkdir -p $APP_CONF_DIR
}

prepare(){
  prepare_deepops
  prepare_helm
}

configure(){
  case $1 in
    cluster)  
      ask_cluster_conf
      setup_no_proxy
      generate_conf
    ;;
    single-node)  
      ask_single_node_conf
      setup_no_proxy
      generate_conf
    ;;
    *)
      echo "configureの引数は cluster, single-node が指定可能です" >&2
      echo "詳細は ${HELP_URL} で確認してください" >&2
      echo "不明なconfigureの引数: $1" >&2
      exit 1
    ;;
  esac  

}


clean(){
  case $1 in
    app)     
      cd $HELM_DIR
      ./deploy-kqi-app.sh clean
    ;;
    nvidia-repo)
      cd $DEEPOPS_DIR
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster $FILES_DIR/deepops/clean-nvidia-docker-repo.yml ${@:2}
    ;;
    all)
      cd $DEEPOPS_DIR
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook kubespray/remove-node.yml --extra-vars "node=k8s-cluster" ${@:2}
    ;;
    *)
      echo "cleanの引数は all, app, nvidia-repo が指定可能です" >&2
      echo "詳細は ${HELP_URL} で確認してください" >&2
      echo "不明なcleanの引数: $1" >&2
      exit 1
    ;;
  esac
}

deploy_nfs(){
  cd $DEEPOPS_DIR
  # nfs-clientを全てのノードに入れる
  ansible-playbook -l all playbooks/nfs-client.yml

  # エラー「ERROR! Specified hosts and/or --limit does not match any hosts」が出ればnfs-serverが指定されていないのでスキップ
  ansible-playbook -l nfs-server --list-hosts playbooks/nfs-server.yml &> /dev/null
  if [ $? -eq 0 ]; then
    ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l nfs-server playbooks/nfs-server.yml $@
  else
    echo "inventoryにnfs-serverが指定されていないため、NFSサーバー構築をスキップします" |& tee -a $LOG_FILE
  fi
}

# ansibleの更新チェック誤作動でgpgの更新が効かない場合に実行する
deploy_nvidia_gpg(){
  cd $DEEPOPS_DIR
  ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster $FILES_DIR/deepops/update-latest-nvidia-gpg.yml $@
}

deploy_k8s(){
  cd $DEEPOPS_DIR
  ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster playbooks/k8s-cluster.yml $@
}

deploy_kqi_helm(){
  cd $HELM_DIR
  if [ -z "$1" ]; then
    echo -en "Admin Passwordを入力: "; read -s PASSWORD
    echo "" # read -s は改行しないため、echoで改行
  else
    PASSWORD=$1
  fi

  ./deploy-kqi-app.sh prepare &&
  PASSWORD=$PASSWORD DB_PASSWORD=$PASSWORD STORAGE_PASSWORD=$PASSWORD ./deploy-kqi-app.sh credentials &&
  ./deploy-kqi-app.sh deploy
}

show_kqi_url(){
  local KQI_HOST=$(sed -rn 's/^kqi_node: "(.*)"$/\1/p' $APP_CONF_FILE)
  echo "http://${KQI_HOST}"
  echo "にアクセスしてください"
}

update(){
  echo -e "アプリのアップデートを開始します"
  cd $HELM_DIR
  ./deploy-kqi-app.sh update
  echo -e "アプリのアップデートが完了しました"
}

# 呼び出しフォーマット: deploy <sub command> <deepopsのコマンドに渡す引数群(${@:2})>
deploy(){
  case $1 in
    infra) deploy_k8s ${@:2} && deploy_nfs ;; 
    nfs) deploy_nfs ${@:2} ;;
    k8s) deploy_k8s ${@:2} ;;
    app) deploy_kqi_helm |& tee -a $LOG_FILE && show_kqi_url ;;
    nvidia-gpg-key) deploy_nvidia_gpg ${@:2} ;;
    all) 
      echo -en "Admin Passwordを入力: "; read -s PASSWORD
      echo "" # read -s は改行しないため、echoで改行
      deploy_k8s ${@:2} &&
      deploy_nfs &&
      deploy_kqi_helm $PASSWORD |& tee -a $LOG_FILE

      if [ $? -eq 0 ]; then
        echo -e "\n\n 構築が完了しました"
        show_kqi_url
      else
        echo -e "構築でエラーが発生しました"
      fi
      ;;
    *)
      echo "deployの引数は all, infra, nfs, k8s, app, nvidia-gpg-key が指定可能です" >&2
      echo "詳細は ${HELP_URL} で確認してください" >&2
      echo "不明なdeployの引数: $1" >&2
      exit 1
    ;;
  esac
}

scale(){
  cd $DEEPOPS_DIR
  ansible-playbook -l k8s-cluster kubespray/scale.yml
  ansible-playbook -l k8s-cluster playbooks/k8s-cluster.yml
}

check(){
  echo "#Kubernetesの状態"
  kubectl version
  echo ""
  echo "Helmの状態"
  helm version
  echo ""
  echo "KAMONOHASHIの状態"
  helm status kamonohashi
}


show_help(){
cat <<EOF
Usage: ./deploy-kamonohashi.sh COMMAND [ARGS] [OPTIONS]

  KAMONOHASHI デプロイスクリプト: ${THIS_SCRIPT_VER}

Commands:
  prepare    構築に利用するツールのインストールを行います
  configure  構築の設定を行います
  deploy     構築します
  update     アプリのアップデートを行います
  clean      アンインストールします
  check      デプロイの状態確認を行います
  scale      ノードの追加を行います
  help       このヘルプを表示します

詳細は ${HELP_URL} で確認してください

EOF
}

main(){
  cd $SCRIPT_DIR
  load_proxy_conf
  set -e
  case $1 in
    prepare) prepare;;
    configure) configure ${@:2};;
    deploy) deploy ${@:2};;
    update) update ${@:2};;
    clean) clean ${@:2};;
    check) check ${@:2};;
    scale) scale ${@:2};;
    help) show_help ;;
    *) show_help ;;
  esac
}

mkdir -p $LOG_DIR
echo "command: $0 $@" >> $LOG_FILE
main $@