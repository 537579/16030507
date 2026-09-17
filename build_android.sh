#!/bin/bash
date

#共通パス設定の読み込み
source setup_env.sh || exit 1

#個別パス設定
base_dir=..
OUT_SYSTEM_DIR="${base_dir}/${QSSI_DIR}/LINUX/android/out/target/product/qssi/system"

echo "UFS_HPB=$UFS_HPB"
echo "UFS_GEAR_RATE=$UFS_GEAR_RATE"
date

############ kernel compile ##########
#pushd使って戻ってくる位置の保存
pushd .
echo "pwd=`pwd`"
#kernelのコンパイルを実行
#./build_kernel.sh full || exit 1
date
#popd使ってpushdで保存した位置に戻る
popd
date

############ QSSI compile ##########
#pushd使って戻ってくる位置の保存
pushd .
echo "pwd=`pwd`"
#QSSIのコンパイルを実行
./build_qssi.sh || exit 1
date
#popd使ってpushdで保存した位置に戻る
popd
date

############ kernel compile ##########
#pushd使って戻ってくる位置の保存
pushd .
echo "pwd=`pwd`"
#VENDORのコンパイルを実行
./build_vendor.sh || exit 1
#popd使ってpushdで保存した位置に戻る
popd
date
