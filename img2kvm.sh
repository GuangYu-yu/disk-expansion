#!/bin/sh

import(){
    img_name=$1
    vm_id=$2
    storage=${3:-local-lvm}
    vmdisk_name=img2kvm_temp.qcow2
    
    
    if [ "${img_name##*.}"x = "gz"x ];then
        echo '--- decompress img file...'
        gzip -d -k ${img_name}
        img_name=${img_name%%.gz*}
        gz_tmp=1
    fi

    echo '--- convert img to qcow2...'
    qemu-img convert -f raw -O qcow2 ${img_name} ${vmdisk_name}

    echo '--- importdisk...'
    qm importdisk ${vm_id} ${vmdisk_name} ${storage}

    echo '--- remove temp file...'
    rm ${vmdisk_name}
    if [ $gz_tmp ];then
        rm ${img_name}
    fi
    echo '--- success'
}

help(){
    echo 'usage:'
    echo '  img2kvm.sh -i <img_name> <vm_id> [storage]'
    echo '  eg: img2kvm.sh -i openwrt.img 100 local-lvm'
}

case $1 in
-h)
    help
    ;;
-i)
    import $2 $3 $4
    ;;
*)
    echo '-h for help'
    ;;
esac
