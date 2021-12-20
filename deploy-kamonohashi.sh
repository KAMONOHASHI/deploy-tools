#!/bin/bash
###
#  定数定義
###
readonly SCRIPT_DIR=$(cd $(dirname $0); pwd)
readonly GIT_TAG=$(cd $SCRIPT_DIR && git tag --points-at HEAD)
readonly GIT_HASH=$(cd $SCRIPT_DIR && git rev-parse HEAD)
readonly THIS_SCRIPT_VER=${GIT_TAG:-$GIT_HASH}

readonly DATE=$(date '+%Y%m%d-%H%M%S')

readonly LOG_DIR=/var/log/kamonohashi/deploy-tools
readonly LOG_FILE=$LOG_DIR/deploy_$DATE.log

readonly HELP_URL="https://kamonohashi.ai/docs/install-and-update"

readonly DEEPOPS_DIR=$SCRIPT_DIR/deepops
readonly DEEPOPS_VER=21.03
readonly OLD_DEEPOPS_VER=20.02.1
readonly HELM_DIR=$SCRIPT_DIR/kamonohashi
readonly FILES_DIR=$SCRIPT_DIR/files
readonly DEEPOPS_FILES_DIR=$FILES_DIR/deepops/$DEEPOPS_VER
readonly OLD_DEEPOPS_FILES_DIR=$FILES_DIR/deepops/$OLD_DEEPOPS_VER

readonly TMP_DIR=/tmp/kamonohashi/$DATE

# deepopsの設定ファイル
readonly INFRA_CONF_DIR=$DEEPOPS_DIR/config
readonly INVENTORY=$INFRA_CONF_DIR/inventory
readonly EXTRA_VARS=$INFRA_CONF_DIR/settings.yml

# KAMONOHASHI Helmの設定ファイル
readonly APP_CONF_DIR=$HELM_DIR/conf
readonly APP_CONF_FILE=$APP_CONF_DIR/settings.yml



############################################################
#  関数定義
############################################################

############
#  入力関連
############

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
  . $DEEPOPS_DIR/scripts/deepops/proxy.sh
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

############
#  設定の生成と書き込み
############

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
cat <<EOF >> $EXTRA_VARS

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
  cp -rfp $DEEPOPS_DIR/config.example $DEEPOPS_DIR/config
  cp $DEEPOPS_$FILES_DIR/deepops/$DEEPOPS_VER/settings.yml $DEEPOPS_DIR/config/
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
  envsubst < $DEEPOPS_FILES_DIR/inventory.template > $INVENTORY
}

generate_helm_conf(){
  mkdir -p $APP_CONF_DIR
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
  if [ -d $INFRA_CONF_DIR ]; then
    mkdir -p $DEEPOPS_DIR/old_config/$DATE
    mv $INFRA_CONF_DIR $DEEPOPS_DIR/old_config/$DATE
  fi
  if [ -d $APP_CONF_DIR ]; then
    mkdir -p $HELM_DIR/old_config/$DATE
    cp -a $APP_CONF_DIR $HELM_DIR/old_config/$DATE
  fi
}

generate_deepops_conf(){
  generate_deepops_vars
  generate_deepops_inventory
}

generate_verup_conf(){
  cd $DEEPOPS_DIR
  mkdir -p $TMP_DIR
  # 元の設定ファイルと比較して変更があったものを書き込む
  python3 $FILES_DIR/diff-yaml.py $INFRA_CONF_DIR/group_vars/all.yml $OLD_DEEPOPS_FILES_DIR/all.yml >> $TMP_DIR/deepops_settings.yml
  python3 $FILES_DIR/diff-yaml.py $INFRA_CONF_DIR/group_vars/k8s-cluster.yml $OLD_DEEPOPS_FILES_DIR/k8s-cluster.yml >> $TMP_DIR/deepops_settings.yml
  cp $INVENTORY $TMP_DIR/inventory
  cp $APP_CONF_FILE $TMP_DIR/kqi_settings.yml
 
  backup_old_conf
  cp -rfp $DEEPOPS_DIR/config.example $DEEPOPS_DIR/config
  cp $DEEPOPS_$FILES_DIR/deepops/$DEEPOPS_VER/settings.yml $DEEPOPS_DIR/config/

  # 異なる設定だけを追記
  python3 $FILES_DIR/diff-yaml.py $TMP_DIR/deepops_settings.yml $INFRA_CONF_DIR/settings.yml >> $INFRA_CONF_DIR/settings.yml 

  
  cp -f $TMP_DIR/inventory $INVENTORY
  cp -f $TMP_DIR/kqi_settings.yml $APP_CONF_FILE
}

generate_conf(){
  backup_old_conf
  generate_deepops_conf
  generate_helm_conf
}

############
#  prepare関連
############

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

############
#  configure関連
############

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
    verup)
      generate_verup_conf
    ;;
    *) show_unknown_arg "configure" "cluster, single-node, verup" $1 ;;
  esac  

}

############
#  clean関連
############

clean(){
  case $1 in
    app)     
      cd $HELM_DIR
      ./deploy-kqi-app.sh clean
    ;;
    nvidia-repo)
      cd $DEEPOPS_DIR
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster $DEEPOPS_FILES_DIR/clean-nvidia-docker-repo.yml -e @$EXTRA_VARS ${@:2}
    ;;
    all)
      cd $DEEPOPS_DIR
      read -p "クラスタ全体のアンインストールを実行してよいですか? (y/n): " YN
      if [ "${YN}" != "y" ]; then
          echo "アンインストールを中止します"
          exit 1
      fi
      NODES=$(ansible all --list-hosts | tail -n +2 | tr -d ' ' | tr '\n' ',')
      # deepopsの指示しているアンインストール方法
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook submodules/kubespray/remove-node.yml -e "node=$NODES" -e "delete_nodes_confirmation='yes'" -e @$EXTRA_VARS ${@:2} || true
      # kubespray本来のアンインストール方法。deepopsの指示しているアンインストール方法ではアンインストールに失敗するケースがあるため実行
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook submodules/kubespray/reset.yml -e "reset_confirmation='yes'" -e @$EXTRA_VARS ${@:2} || true
      # 上記2つでも途中でエラーになりアンインストールに失敗するケースがあるため、エラー箇所以降を抜粋したplaybookを実行
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook $DEEPOPS_FILES_DIR/post-clean-all.yml -e "node=$NODES" -e "kubespray_dir='/var/lib/kamonohashi/deploy-tools/deepops/submodules/kubespray/'" -e @$EXTRA_VARS ${@:2}
      # nvidia packageのアンインストール
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster $DEEPOPS_FILES_DIR/clean-nvidia-packages.yml -e @$EXTRA_VARS ${@:2}
    ;;
    nvidia-packages)
      cd $DEEPOPS_DIR
      ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster $DEEPOPS_FILES_DIR/clean-nvidia-packages.yml -e @$EXTRA_VARS ${@:2}
    ;;
    *) show_unknown_arg "clean" "all, app, nvidia-repo, nvidia-packages" $1 ;;
  esac
}

############
#  deploy関連
############

deploy_nfs(){
  cd $DEEPOPS_DIR
  local NFS_PLAYBOOK_DIR=$DEEPOPS_FILES_DIR
  # nfs-clientを全てのノードに入れる
  ansible-playbook -l all $NFS_PLAYBOOK_DIR/nfs-client.yml -e @$EXTRA_VARS

  # エラー「ERROR! Specified hosts and/or --limit does not match any hosts」が出ればnfs-serverが指定されていないのでスキップ
  ansible-playbook -l nfs-server --list-hosts $NFS_PLAYBOOK_DIR/nfs-server.yml &> /dev/null
  if [ $? -eq 0 ]; then
    ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l nfs-server $NFS_PLAYBOOK_DIR/nfs-server.yml -e @$EXTRA_VARS $@
  else
    echo "inventoryにnfs-serverが指定されていないため、NFSサーバー構築をスキップします" |& tee -a $LOG_FILE
  fi
}

# ansibleの更新チェック誤作動でgpgの更新が効かない場合に実行する
deploy_nvidia_gpg(){
  cd $DEEPOPS_DIR
  ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster $DEEPOPS_FILES_DIR/update-latest-nvidia-gpg.yml -e @$EXTRA_VARS $@
}

deploy_k8s(){
  cd $DEEPOPS_DIR
  ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -l k8s-cluster playbooks/k8s-cluster.yml -e @$EXTRA_VARS $@
  # kubelet_rotate_server_certificates: true の場合、kubectl certificate approveが必要
  update_kube_certs
}

deploy_kqi_helm(){
  cd $HELM_DIR
  if [ -z "$1" ]; then
    echo -en "Admin Passwordを入力: "; read -s PASSWORD
    echo "" # read -s は改行しないため、echoで改行
  else
    PASSWORD=$1
  fi

  # ./deploy-kqi-app.sh prepare &&
  PASSWORD=$PASSWORD DB_PASSWORD=$PASSWORD STORAGE_PASSWORD=$PASSWORD ./deploy-kqi-app.sh credentials &&
  ./deploy-kqi-app.sh deploy
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
    *) show_unknown_arg "deploy" "all, infra, nfs, k8s, app, nvidia-gpg-key" $1 ;;
  esac
}

############
#  update関連
############

update_app(){
  echo -e "アプリのアップデートを開始します"
  cd $HELM_DIR
  ./deploy-kqi-app.sh update
  echo -e "アプリのアップデートが完了しました"
}

update_node_conf(){
  cd $DEEPOPS_DIR
  ansible-playbook -l k8s-cluster submodules/kubespray/scale.yml -e @$EXTRA_VARS $@
  ansible-playbook -l k8s-cluster playbooks/k8s-cluster.yml -e @$EXTRA_VARS $@
  ansible-playbook -l all $DEEPOPS_FILES_DIR/nfs-client.yml -e @$EXTRA_VARS $@
}

update_kube_certs(){
  # kubelet serving 証明書の承認
  # https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet-tls-bootstrapping/#client-and-serving-certificates
  kubectl get csr -o name | xargs -I {} kubectl certificate approve {}
  # masterの証明書更新
  kubeadm alpha certs renew all
}

set_credentials(){
  case $1 in
    storage)
      update_storage_password ;;
    db)
       ;;
    all)
      echo -en "Admin Passwordを入力: "; read -s PASSWORD
      echo "" # read -s は改行しないため、echoで改行
      
      set_storage_credentials $PASSWORD
      ;;
    *)
      show_unknown_arg "password" "storage, db, all" $1 ;;
  esac
}

set_storage_credentials(){
  cd $HELM_DIR
  if [ -z "$1" ]; then
    echo -en "\n\e[33mStorage Secret Keyを入力: \e[m"; read -s STORAGE_PASSWORD
    echo "" # read -s は改行しないため、echoで改行
  else
    STORAGE_PASSWORD=$1
  fi

  # credentials更新
  STORAGE_PASSWORD=$STORAGE_PASSWORD ./deploy-kqi-app.sh credentials
  # Podを再起動
  kubectl rollout restart deploy minio --namespace kqi-system
}

update(){
  case $1 in
    app) update_app ;;
    node-conf) update_node_conf ${@:2} ;;
    kube-certs) update_kube_certs;;
    credentials) set_credentials ${@:2};;
    *) show_unknown_arg "update" "app, node-conf, kube-certs, credentials" $1 ;;
  esac
}



############
#  check関連
############

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

############
#  ヘルプメッセージ関連
############

show_kqi_url(){
  local KQI_HOST=$(sed -rn 's/^kqi_node: "(.*)"$/\1/p' $APP_CONF_FILE)
  echo "http://${KQI_HOST}"
  echo "にアクセスしてください"
}

# 利用フォーマット: show_unknown_arg <サブコマンド名> <指定可能引数> <指定された引数>
show_unknown_arg(){
  echo "$1の引数は $2 が指定可能です" >&2
  echo "詳細は ${HELP_URL} で確認してください" >&2
  echo "不明な$1の引数: $3" >&2
  exit 1  
}

show_help(){
cat <<EOF
Usage: ./deploy-kamonohashi.sh COMMAND [ARGS] [OPTIONS]

  KAMONOHASHI デプロイスクリプト: ${THIS_SCRIPT_VER}

Commands:
  prepare    構築に利用するツールのインストールを行います
  configure  構築の設定を行います
  deploy     構築します
  update     アプリのアップデートまたはクラスタ設定の更新反映を行います
  clean      アンインストールします
  check      デプロイの状態確認を行います
  help       このヘルプを表示します

詳細は ${HELP_URL} で確認してください

EOF
}

############
#  メイン
############

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
    help) show_help ;;
    *) show_help ;;
  esac
}

############################################################
#  エントリーポイント
############################################################

mkdir -p $LOG_DIR
echo "command: $0 $@" >> $LOG_FILE
main $@
