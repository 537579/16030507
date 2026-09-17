#!/bin/bash

date

#共通パス設定の読み込み
source setup_env.sh || exit 1

############## 個別パスの設定 #################
base_dir=..

##8650では未実装の為、削除
##IRQバランス設定のコピー先
#OUT_VENDOR_DIR="./LINUX/android/out/target/product/${KERNEL_CODE_NAME}/vendor"
#VENDOR_PREBUILD_DIR="./LINUX/android/vendor/qcom/proprietary/prebuilt_HY11/target/product/${KERNEL_CODE_NAME}/vendor/etc"

#ベンチマークスクリプトのコピー元
BUILD_DIR=$(cd $(dirname $0);pwd)
BENCH_MARK_DIR="${BUILD_DIR}/benchmark"
echo "BUILD_DIR=$BUILD_DIR"
echo "BENCH_MARK_DIR=$BENCH_MARK_DIR"



echo "UFS_HPB=$UFS_HPB"
echo "UFS_GEAR_RATE=$UFS_GEAR_RATE"

#カレントディレクトリをpushdで保存しながら
#Vendor buildの実行ディレクトリへ移動
pushd ${base_dir}/${VENDOR_DIR}

#フルコンパイル用の一時ファイルの削除
rm -rf ./LINUX/android/kernel_platform/bazel-cache/*
rm -rf ./LINUX/android/kernel_platform/out
rm -rf ./LINUX/android/bazel-cache/*
rm -rf ./LINUX/android/out

#qssi,kernelソースのコピー
./1.build_kernel.sh || exit 1
./2.qssi_cp.sh || exit 1

##8650では未実装の為、削除
##IRQバランス設定のコピー
#echo "copying ${BUILD_DIR}/msm_irqbalance/msm_irqbalance.conf ${OUT_VENDOR_DIR}/etc/"
#echo "copying ${BUILD_DIR}/msm_irqbalance/msm_irqbalance.conf ${VENDOR_PREBUILD_DIR}"
#mkdir -p ${OUT_VENDOR_DIR}/etc/
#cp ${BUILD_DIR}/msm_irqbalance/msm_irqbalance.conf ${OUT_VENDOR_DIR}/etc/
#cp ${BUILD_DIR}/msm_irqbalance/msm_irqbalance.conf ${VENDOR_PREBUILD_DIR}

#benchmarkスクリプトのコピー(スクリプト修正後にQSSIコンパイルしなくても反映される様に対策)
# copy benchmark script(need compile complate once.)
if [ ! -e ${OUT_SYSTEM_DIR} ];then
	mkdir -p ${OUT_SYSTEM_DIR}/xbin
	mkdir -p ${OUT_SYSTEM_DIR}/etc
	mkdir -p ${OUT_SYSTEM_DIR}/app
fi
echo "copying ${BENCH_MARK_DIR}/benchmark.sh ${OUT_SYSTEM_DIR}/xbin/"
cp ${BENCH_MARK_DIR}/benchmark.sh ${OUT_SYSTEM_DIR}/xbin/
cp -r ${BENCH_MARK_DIR}/benchmark ${OUT_SYSTEM_DIR}/etc/
cp -r ${BENCH_MARK_DIR}/AndroBench501 ${OUT_SYSTEM_DIR}/app/

#Vendor buildとマージ実行
./3.target_build.sh || exit 1
./4.merge.sh || exit 1

#popdを使用してpushdで保存したディレクトリへ移動
popd

date
