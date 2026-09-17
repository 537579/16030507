#!/bin/bash

#共通パス設定の読み込み
source setup_env.sh || exit 1

build_dir=`pwd`

function print_help(){
    echo "Options help please refer to 00_readme.txt"
}

#引数にhelpがあったらhelpを表示
for opt_loop in "$@";do
	if [ "$opt_loop" == "help" ];then
		print_help
		exit 1
	fi
done

#スクリプト実行場所の取得
SCRIPT_DIR=$(cd $(dirname $0); pwd)
echo $SCRIPT_DIR
cd $SCRIPT_DIR

##################### パス設定 ########################################
UFS_VENDOR_PATH="${VENDOR_DIR}/LINUX/android"
UFS_QSSI_PATH="${QSSI_DIR}/LINUX/android"
base_dir="${SCRIPT_DIR}/.."

CONFIG_MODEL_COPY_TO_PATH="${UFS_VENDOR_PATH}/device/qcom/${KERNEL_CODE_NAME}"
CONFIG_FSTAB_COPY_TO_PATH="${CONFIG_MODEL_COPY_TO_PATH}"
CONFIG_QSSI_COPY_TO_PATH="${UFS_QSSI_PATH}/device/qcom/qssi"
CONFIG_PATITION_COPY_TO_PATH="${PRODUCT_DIR}/common/config/ufs"
CONFIG_UFS_DTSI_COPY_TO_PATH="${UFS_BOOT_PATH}/boot_images/boot/Settings/Soc/${SOC_CODE_NAME}/Default/Core/Storage/UFS"
CONFIG_MTP_DTSI_COPY_TO_PATH="${KERNEL_PLATFORM_DIR}/qcom/opensource/devicetree/qcom"
#CONFIG_QVIRTMGR_VNDR_JSON_COPY_TO_PATH="${VENDOR_DIR}/LINUX/android/vendor/qcom/opensource/prebuilt_HY11/target/product/${KERNEL_CODE_NAME}/vendor/etc"

### デフォルト設定 ###
CURRENT_DATE=$(date "+%Y%m%d")
FILESYSTEM="f2fs"
UFS_GEAR_RATE="G5B"
ENCRYPTION="noEnc"
COMPRESS_PATTERN=0
FILE_COPY=0
BUILD_TARGET=full
BUILD_NONHLOS_PATTERN=2
SKIP_BRANCHCHECK=0
DEBUG_PATTERN=""
CONFIG_CHANGE_SKIP=0
SETTING_MENU_ENABLE=0
MCQ="useMcq"
FORCE_WB_DISABLE=0
FORCE_DURING_HIBER_ENABLE=0
FORCE_BKOPS_DISABLE=0
UFS_FUA1=0
UFS_CP1=0

#シェルの引数を解析して各変数へ反映する
for opt_loop in "$@";do
	case "$opt_loop" in
		[eE][xX][tT]4 | [fF]2[fF][sS] ) FILESYSTEM=$opt_loop ;;
		[gG]5[aA] | [gG]5[bB] | [gG]4[aA] | [gG]4[bB] | [gG]3[aA] | [gG]3[bB] ) UFS_GEAR_RATE=$opt_loop ;;
		"noEnc" | "FBE" | "FBE-meta" ) ENCRYPTION=$opt_loop ;;
		[nN][oO][nN]_[hH][lL][oO][sS] | [nN][oO][nN][hH][lL][oO][sS] ) BUILD_NONHLOS_PATTERN=1 ;;
		"noMcq" | "useMcq" ) MCQ=$opt_loop ;;
		"dist" | "kernel" | "full" ) BUILD_TARGET=$opt_loop ;;
		"copy" | "c" ) FILE_COPY=1 ;; #一括作成の場合は最後にサーバへコピーするのでコピーしない設定をしておく
		"debug" ) DEBUG_PATTERN=$opt_loop  ;;
		"menu" ) SETTING_MENU_ENABLE=1  ;;
		"wb_disable" ) FORCE_WB_DISABLE=1 ;;
		"during_hiber_enable" ) FORCE_DURING_HIBER_ENABLE=1 ; FORCE_WB_DISABLE=1 ;;
		"bkops_disable" ) FORCE_BKOPS_DISABLE=1 ;;
		[fF][uU][aA]1 ) UFS_FUA1=1 ;;
		[cC][pP]1 ) UFS_CP1=1 ;;
	esac

	if [ "`echo $opt_loop | grep 'DIR='`" ];then
		IMAGE_DIR_BASE=`echo ${opt_loop:4}`
	fi
done

FILESYSTEM=`echo "${FILESYSTEM}" | tr '[:upper:]' '[:lower:]'`
UFS_GEAR_RATE=`echo "${UFS_GEAR_RATE}" | tr '[:lower:]' '[:upper:]'`

################### オプションでmenuを指定した場合は対話形式で設定する様に ##################
################### 一旦、設定値をリセットする                             ##################
if [ $SETTING_MENU_ENABLE -eq 1 ];then
	unset FILESYSTEM
	unset UFS_GEAR_RATE
	unset ENCRYPTION
	unset BUILD_TARGET
	unset BUILD_NONHLOS_PATTERN
	unset MCQ
	echo "FILESYSTEM=$FILESYSTEM"
	echo "UFS_GEAR_RATE=$UFS_GEAR_RATE"
	echo "ENCRYPTION=$ENCRYPTION"
	echo "BUILD_TARGET=$BUILD_TARGET"
	echo "BUILD_NONHLOS_PATTERN=$BUILD_NONHLOS_PATTERN"
	echo "MCQ=${MCQ}"
fi

#userdateエリアのファイルシステムを設定
echo ""
echo "********************************************************"
echo "Please select File System"
echo "********************************************************"
echo "1. ext4"
echo "2. f2fs"
echo "********************************************************"
echo -n "File System pattern? : "

if [ ${#FILESYSTEM} -eq 0 ];then
	read FILESYSTEM_PATTERN
else
	case ${FILESYSTEM} in
		"ext4" ) FILESYSTEM_PATTERN=1 ;;
		"f2fs" ) FILESYSTEM_PATTERN=2 ;;
	esac
	echo "$FILESYSTEM_PATTERN"
fi


if [ ${FILESYSTEM_PATTERN} -eq 1 ]; then
	FS_STR="ext4"
elif [ ${FILESYSTEM_PATTERN} -eq 2 ]; then
	FS_STR="f2fs"
else
	echo "File System pattern is invalid."
	echo "Please retry."
	exit 1
fi

echo ""
echo "********************************************************"
echo "Please select Encryption"
echo "********************************************************"
echo "1. noEnc"
echo "2. FBE"
echo "3. FBE + metadata"
echo "********************************************************"
echo -n "Encryption pattern? : "

if [ ${#ENCRYPTION} -eq 0 ];then
	read ENCRYPTION_PATTERN
else
	case ${ENCRYPTION} in
		"noEnc" ) ENCRYPTION_PATTERN=1 ;;
		"FBE" ) ENCRYPTION_PATTERN=2 ;;
		"FBE-meta" ) ENCRYPTION_PATTERN=3 ;;
	esac
	echo "$ENCRYPTION_PATTERN"
fi

if [ ${ENCRYPTION_PATTERN} -eq 1 ]; then
	ENC_STR="noEnc"
elif [ ${ENCRYPTION_PATTERN} -eq 2 ]; then
	ENC_STR="FBE"
elif [ ${ENCRYPTION_PATTERN} -eq 3 ]; then
	ENC_STR="FBE-meta"
else
	echo "Encryption pattern is invalid."
	echo "Please retry."
	exit 1
fi

echo ""
echo "********************************************************"
echo "Please select Rate"
echo "********************************************************"
echo "1. RateA (HS-G4A)"
echo "2. RateB (HS-G4B)"
echo "3. RateA (HS-G3A)"
echo "4. RateB (HS-G3B)"
echo "5. RateA (HS-G5A)"
echo "6. RateB (HS-G5B)"
echo "********************************************************"
echo -n "Rate pattern? : "

if [ ${#UFS_GEAR_RATE} -eq 0 ];then
	read RATE_PATTERN
else
	case ${UFS_GEAR_RATE} in
		"G4A" ) RATE_PATTERN=1 ;;
		"G4B" ) RATE_PATTERN=2 ;;
		"G3A" ) RATE_PATTERN=3 ;;
		"G3B" ) RATE_PATTERN=4 ;;
		"G5A" ) RATE_PATTERN=5 ;;
		"G5B" ) RATE_PATTERN=6 ;;
	esac
	echo "$RATE_PATTERN"
fi

case ${RATE_PATTERN} in
	1 | 2 | 3 | 4 | 5 | 6 ) ;;
	* ) echo "gear/rate pattern is invalid." ; echo "Please retry." ; exit 1 ;;
esac

echo ""
echo "********************************************************"
echo "Please select MCQ"
echo "********************************************************"
echo "1. useMcq"
echo "2. noMcq"
echo "********************************************************"
echo -n "MCQ pattern? : "

if [ ${#MCQ} -eq 0 ];then
	read MCQ_PATTERN
	case ${MCQ_PATTERN} in
		"1" ) MCQ="useMcq" ;;
		"2" ) MCQ="noMcq" ;;
		* ) echo "Invalid Mcq pattern"; exit 1 ;;
	esac
else
	echo "${MCQ}"
fi

while : ; do
	echo ""
	echo "********************************************************"
	echo "Build target?"
	echo "********************************************************"
	echo "1. kernel only.(nonHLOS build choise next setp.)"
	echo "2. full build."
	echo "********************************************************"
	echo -n "Build target? : "

	if [ -z ${BUILD_TARGET} ] ; then
		read BUILD_TARGET
		case $BUILD_TARGET in
			1 | "kernel" ) BUILD_TARGET="kernel" ; break 1 ;;
			2 | "full" ) BUILD_TARGET="full" ; BUILD_NONHLOS_PATTERN=1 : break 1 ;;
			* ) echo "nonHLOS build pattern is invalid." ; echo "Please retry." ;;
		esac
	else
		echo "BUILD_TARGET=$BUILD_TARGET"
		break 1
	fi
done

if [ $BUILD_TARGET == "kernel" ];then
	while : ; do
		echo ""
		echo "********************************************************"
		echo "Build nonHLOS?"
		echo "********************************************************"
		echo "1. Yes"
		echo "2. No"
		echo "********************************************************"
		echo -n "Build nonHLOS? : "

		if [ -z ${BUILD_NONHLOS_PATTERN} ] ; then
			read BUILD_NONHLOS_PATTERN
			case $BUILD_NONHLOS_PATTERN in
				1 | 2 ) break 1 ;;
				* ) echo "nonHLOS build pattern is invalid." ; echo "Please retry." ;;
			esac
		else
			echo "BUILD_NONHLOS_PATTERN=$BUILD_NONHLOS_PATTERN"
			break 1
		fi
	done
fi

if [ $BUILD_TARGET == "kernel" ];then
	if [ ! -e ../${UFS_QSSI_PATH}/out ];then
		echo ""
		echo "../${UFS_QSSI_PATH}/out がありません。"
		echo "QSSIがコンパイルされていないと思われるので"
		echo "左記のオプションでコンパイルを実行して下さい。 ./create_image.sh full"
		exit
	fi
fi

loop=1
if [ ${#IMAGE_DIR_BASE} -eq 0 ];then
	if [ ! -d ${FS_STR} ];then
		mkdir ${FS_STR}
	fi
	pushd ${FS_STR}
	while :;do
		HOST_NAME=`hostname -I | cut -d ' ' -f 1`
		HOST_NAME=`echo ${HOST_NAME} | sed -e "s/[\r\n]\+//g"`

		IMAGE_DIR_BASE=${CURRENT_DATE}_${loop}_${HOST_NAME}
		RES=`ls`
		if [ -n "`echo $RES | grep $IMAGE_DIR_BASE`" ];then
			loop=$((loop+1))
		else
			break
		fi
	done
	popd
fi

echo "下記の設定で5秒後にコンパイルを開始します。"
echo "
FILESYSTEM=$FILESYSTEM
UFS_GEAR_RATE=$UFS_GEAR_RATE
ENCRYPTION=$ENCRYPTION
MCQ=$MCQ
BUILD_TARGET=$BUILD_TARGET"
case ${BUILD_NONHLOS_PATTERN} in
	1 ) echo "nonHLOS buildする" ;;
	2 | * ) echo "nonHLOS buildしない" ;;
esac
if [ $COMPRESS_PATTERN -eq 1 ];then
	echo "イメージ作成後に圧縮ファイルを作成する"
else
	echo "イメージ作成後に圧縮ファイルを作成しない"
fi
if [ $FILE_COPY -eq 1 ];then
	echo "イメージ作成後にサーバにファイルをコピーする"
else
	echo "イメージ作成後にサーバにファイルをコピーしない"
fi
if [ $SKIP_BRANCHCHECK -eq 1 ];then
	echo "branch名のチェックをする"
else
	echo "branch名のチェックをしない"
fi
if [ ${FORCE_WB_DISABLE} -eq 1 ];then
	echo "write booster 強制OFF"
fi
if [ $FORCE_DURING_HIBER_ENABLE -eq 1 ];then
	echo "write booster 強制OFFでもWB Flush During Hibernate を有効にする"
fi
if [ $FORCE_BKOPS_DISABLE -eq 1 ];then
	echo "BKOPS 強制的OFF"
fi
if [ $UFS_FUA1 -eq 1 ];then
	echo "FUA1 enable"
fi
if [ $UFS_CP1 -eq 1 ];then
	echo "CP1 enable"
fi

sleep 5

#echo "********************************************************"
#echo "IMAGE_DIR_BASE=$IMAGE_DIR_BASE"
#echo "********************************************************"

###############################################################
# config_file下の各ファイルシステムに対応する設定ファイルと
# コンパイル環境の対応する設定ファイルを比較して
# 変更が必要なファイルをコピーする
###############################################################

###### userdata file system変更等のConfig変更処理 #############
###### 処理をSKIPしたい時はCONFIG_CHANGE_SKIPを1にする  #############
if [ $CONFIG_CHANGE_SKIP -ne 1 ];then

###### /dataパーティションのf2fs/ext4切替の為に入れ替え必要なファイルの差分チェックとコピーの実施  開始  ######
	### fstab.qcomの比較と必要ならコピーする
	#diffの戻り値が0なら差分無しの為、コピー不要
	echo "fstab.qcom copy check."
	diff_to_copy_func ${CONFIG_FSTAB_COPY_TO_PATH} fstab.qcom.${FS_STR}.${ENC_STR} fstab.qcom
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied fstab.qcom.${FS_STR}.${ENC_STR} !"
		cat  ${base_dir}/${CONFIG_FSTAB_COPY_TO_PATH}/fstab.qcom | grep "/data"
	else
		echo "fstab.qcom don't copy."
	fi

	# change BoardConfig.mk
	echo "BoardConfig.mk copy check."
	diff_to_copy_func ${CONFIG_MODEL_COPY_TO_PATH} BoardConfig.mk.${FS_STR} BoardConfig.mk
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied BoardConfig.mk.${FS_STR} !"
		cat ${base_dir}/${CONFIG_MODEL_COPY_TO_PATH}/BoardConfig.mk | grep TARGET_USERIMAGES_USE_EXT4
	else
		echo "BoardConfig.mk don't copy."
	fi

	# change recovery.fstab
	echo "recovery.fstab copy check."
	diff_to_copy_func ${CONFIG_MODEL_COPY_TO_PATH} recovery.fstab.${FS_STR} recovery.fstab
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied recovery.fstab.${FS_STR} !"
		cat ${base_dir}/${CONFIG_MODEL_COPY_TO_PATH}/recovery.fstab | grep /dev/block/bootdevice/by-name/metadata
		cat ${base_dir}/${CONFIG_MODEL_COPY_TO_PATH}/recovery.fstab | grep /dev/block/bootdevice/by-name/userdata
	else
		echo "recovery.fstab don't copy."
	fi
	## change qssi BoardConfig.mk
	#diff config_files/${CONFIG_QSSI_COPY_TO_PATH}/BoardConfig.mk ${base_dir}/${CONFIG_QSSI_COPY_TO_PATH}/BoardConfig.mk
	#DIFF_RESULT=$?
	#echo "DIFF_RESULT=$DIFF_RESULT"
	#if [ ! $DIFF_RESULT -eq 0 ];then
	#echo "DIFF_RESULT2=$DIFF_RESULT"
	#	cp config_files/${CONFIG_QSSI_COPY_TO_PATH}/BoardConfig.mk ${base_dir}/${CONFIG_QSSI_COPY_TO_PATH}/BoardConfig.mk
	#fi
###### /dataパーティションのf2fs/ext4切替の為に入れ替え必要なファイルの差分チェックとコピーの実施  完了  ######

###### 追い込みイメージ用に各LU、ファイルシステムパーティションのサイズ変更に伴う容量設定ファイルの差分チェックとコピーの実施  開始  ######
###### kernelソースgit管理に含めると不要な管理対象が増えてしまう為、build用gitで管理してコピーする様にしている                       ######
	## change partion_ext.xml
	echo "partition_ext.xml copy check."
	diff_to_copy_func ${CONFIG_PATITION_COPY_TO_PATH} partition_ext.xml partition_ext.xml
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied partition_ext.xml !"
	else
		echo "partition_ext.xml don't copy."
	fi

	# change partion_ext_nole.xml
	echo "partition_ext_nole.xml copy check."
	diff_to_copy_func ${CONFIG_PATITION_COPY_TO_PATH} partition_ext_nole.xml partition_ext_nole.xml
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied partition_ext_nole.xml !"
	else
		echo "partition_ext_nole.xml don't copy."
	fi
###### 追い込みイメージ用に各LU、ファイルシステムパーティションのサイズ変更に伴う容量設定ファイルの差分チェックとコピーの実施  終了  ######

###### MCQ、WB強制OFF、During Hiber8 Flush、BKOPS OFF、FUA1等、kernel起動パラメータで動作変更するdtsiファイルのコピー  開始 ######
###### kernelソースgit管理に含めると不要な管理対象が増えてしまう為、build用gitで管理してコピーする様にしている            ######
	if [ ${FORCE_WB_DISABLE} -eq 1 ];then
		WB_FORCE_OFF="_WBForceOff"
		DURING_HIBER_ENABLE="_DuringHiberOff"
	fi
	if [ $FORCE_DURING_HIBER_ENABLE -eq 1 ];then
		WB_FORCE_OFF="_WBForceOff"
		DURING_HIBER_ENABLE="_DuringHiberOn"
	fi
	if [ $FORCE_BKOPS_DISABLE -eq 1 ];then
		BKOPS_DISABLE="_BKOPSOff"
	fi
	if [ $UFS_FUA1 -eq 1 ];then
		UFS_FUA1_ENABLE="_FUA1"
	fi
	if [ $UFS_CP1 -eq 1 ];then
		UFS_CP1_ENABLE="_CP1"
	fi
	
	# change ${KERNEL_CODE_NAME}-v2.dtsi
	echo "${KERNEL_CODE_NAME}-v2.dtsi copy check."
	diff_to_copy_func ${CONFIG_MTP_DTSI_COPY_TO_PATH} ${KERNEL_CODE_NAME}-v2.dtsi.${MCQ}${WB_FORCE_OFF}${DURING_HIBER_ENABLE}${BKOPS_DISABLE}${UFS_FUA1_ENABLE}${UFS_CP1_ENABLE} ${KERNEL_CODE_NAME}-v2.dtsi
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied ${KERNEL_CODE_NAME}-v2.dtsi !"
	else
		echo "${KERNEL_CODE_NAME}-v2.dtsi don't copy."
	fi
###### MCQ、WB強制OFF、During Hiber8 Flush、BKOPS OFF、FUA1等、kernel起動パラメータで動作変更するdtsiファイルのコピー  終了 ######

####### Silver cpuで発行したコマンドのresponseを受けるCPUがデフォルトだとcpu 0-2(Silver CPU)に割り当てられている。                           ######
####### 性能向上の一環としてGold/Prime CPUと同じCPU7(Prime CPU)に割り当てる様に変更した device treeファイルの差分チェックとコピー実施  開始  ######
####### kernelソースgit管理に含めると不要な管理対象が増えてしまう為、build用gitで管理してコピーする様にしている                              ######
#	# change ${KERNEL_CODE_NAME}-vm.dtsi
#	echo "${KERNEL_CODE_NAME}-vm.dtsi copy check."
#	diff_to_copy_func ${CONFIG_MTP_DTSI_COPY_TO_PATH} ${KERNEL_CODE_NAME}-vm.dtsi ${KERNEL_CODE_NAME}-vm.dtsi
#	echo "DIFF_RESULT_XX=$DIFF_RESULT"
#	if [ ! $DIFF_RESULT -eq 0 ];then
#		echo "copied ${KERNEL_CODE_NAME}-vm.dtsi !"
#	else
#		echo "${KERNEL_CODE_NAME}-vm.dtsi don't copy."
#	fi
####### Silver cpuで発行したコマンドのresponseを受けるCPUがデフォルトだとcpu 0-2(Silver CPU)に割り当てられている。                           ######
####### 性能向上の一環としてGold/Prime CPUと同じCPU7(Prime CPU)に割り当てる様に変更した device treeファイルの差分チェックとコピー実施  終了  ######

###### HS Max GearとReference Clock Ratio(Rate-A/B)切替の為に入れ替え必要なファイルの差分チェックとコピーの実施  開始  ######
	## gear rate 変更用ファイルのsuffix文字列設定
	case ${RATE_PATTERN} in
		1 ) GEAR_RATE_STR=g4a ;;
		2 ) GEAR_RATE_STR=g4b ;;
		3 ) GEAR_RATE_STR=g3a ;;
		4 ) GEAR_RATE_STR=g3b ;;
		5 ) GEAR_RATE_STR=g5a ;;
		6 | * ) GEAR_RATE_STR=g5b  ;;
	esac

	echo "GEAR_RATE_STR=${GEAR_RATE_STR}"

	## change ufs.dtsi
	echo "ufs.dtsi copy check."
	diff_to_copy_func ${CONFIG_UFS_DTSI_COPY_TO_PATH} ufs.dtsi.${GEAR_RATE_STR} ufs.dtsi
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied ufs.dtsi.${GEAR_RATE_STR} !"
	else
		echo "ufs.dtsi don't copy."
	fi

	## change ${KERNEL_CODE_NAME}-mtp.dtsi
	echo "${KERNEL_CODE_NAME}-mtp.dtsi copy check."
	diff_to_copy_func ${CONFIG_MTP_DTSI_COPY_TO_PATH} ${KERNEL_CODE_NAME}-mtp.dtsi.${GEAR_RATE_STR} ${KERNEL_CODE_NAME}-mtp.dtsi
	echo "DIFF_RESULT_XX=$DIFF_RESULT"
	if [ ! $DIFF_RESULT -eq 0 ];then
		echo "copied ${KERNEL_CODE_NAME}-mtp.dtsi.${GEAR_RATE_STR} !"
	else
		echo "${KERNEL_CODE_NAME}-mtp.dtsi don't copy."
	fi
###### HS Max GearとReference Clock Ratio(Rate-A/B)切替の為に入れ替え必要なファイルの差分チェックとコピーの実施  終了  ######

fi

## gear rate str setting
case ${RATE_PATTERN} in
	1 ) RATE_STR="_HS-G4A" ;;
	2 ) RATE_STR="_HS-G4B" ;;
	3 ) RATE_STR="_HS-G3A" ;;
	4 ) RATE_STR="_HS-G3B" ;;
	5 ) RATE_STR="_HS-G5A" ;;
	6 | * ) RATE_STR="" ;;
esac

date

#コンパイル対象をkernelに設定した場合(default)　kernel build、Vendor buildを行う
	if [ $BUILD_TARGET = "kernel" ];then
#		echo "call ./build_kernel.sh "
#		./build_kernel.sh || exit 1

		./build_vendor_wo_qssi.sh || exit 1

#コンパイル対象を全ビルドに設定した場合　Kernel、QSSI、Vendor buildを行う。
	elif [ $BUILD_TARGET = "full" ];then
		echo "call ./build_android.sh"
		./build_android.sh || exit 1

#コンパイル対象がどれにも当てはまらない場合　fail safeとしてKernel、QSSI、Vendor buildを行う。
	else
		echo "call ./build_android.sh"
		./build_android.sh || exit 1
	fi

#non_HLOSもビルド対象に設定した場合か全ビルドを設定した場合に non_HLOSをコンパイルする
	if [ ${BUILD_NONHLOS_PATTERN} -eq 1 ]; then
		echo "call ./build_nonHLOS.sh"
		./build_nonHLOS.sh || exit 1
	elif [ $BUILD_TARGET = "full" ];then
		echo "call ./build_nonHLOS.sh"
		./build_nonHLOS.sh || exit 1
	fi

#qfil_sm${SOC_PRODUCT_NAME}_ufs.shを使用してイメージ作成を行う。
	./build_image.sh ${DEBUG_PATTERN} || exit 1

#イメージ作成後、日付情報等を追加して判別し易い様にして配置する
	date
	IMAGE_DIR_TOP=${FS_STR}
	IMAGE_PRODUCT="qfil_sm${SOC_PRODUCT_NAME}_${SOC_PRODUCT_REV}_ufs"
	IMAGE_PRODUCT_MOVE="qfil_sm${SOC_PRODUCT_NAME}"
    if [ -z "${DEBUG_PATTERN}" ]; then
        IMAGE_ORIGINAL_DIR=${IMAGE_PRODUCT}_`date "+%Y%m%d"`
    else
        IMAGE_ORIGINAL_DIR=${IMAGE_PRODUCT}_${DEBUG_PATTERN}_`date "+%Y%m%d"`
    fi

	echo 'DATE=`date "+%Y%m%d"`'
	echo "IMAGE_PRODUCT=${IMAGE_PRODUCT}"
	echo "IMAGE_ORIGINAL_DIR=${IMAGE_ORIGINAL_DIR}"

	if [ ${FORCE_WB_DISABLE} -eq 1 ] ;then
		WB_OPTIONS="_WBforceOff_DuringHibernateOff"
		if [ ${FORCE_DURING_HIBER_ENABLE} -eq 1 ] ;then
			WB_OPTIONS="_WBforceOff_DuringHibernateOn"
		fi
		if [ ${FORCE_BKOPS_DISABLE} -eq 1 ] ;then
			BKOPS_OPTIONS="_BKOPSOff"
		else
			BKOPS_OPTIONS="_BKOPSOn"
		fi
	else
		if [ ${FORCE_BKOPS_DISABLE} -eq 1 ] ;then
			BKOPS_OPTIONS="_BKOPSOff"
		fi
	fi
	if [ ${UFS_FUA1} -eq 1 ] ;then
		FUA1_OPTIONS="_FUA1"
	fi
	if [ ${UFS_CP1} -eq 1 ] ;then
		CP1_OPTIONS="_CP1"
	fi


#	IMAGE_NAME="${IMAGE_PRODUCT}_${FS_STR}${F2FS_OPT_STR}_AH-1ms_${ENC_STR}${HPB_STR}${RATE_STR}${MCQ}_${IMAGE_DIR_BASE}"
	IMAGE_NAME="${IMAGE_PRODUCT_MOVE}_${FS_STR}_${ENC_STR}${RATE_STR}_${MCQ}_${IMAGE_DIR_BASE}${WB_OPTIONS}${BKOPS_OPTIONS}${FUA1_OPTIONS}${CP1_OPTIONS}"
	echo "IMAGE_DIR_TOP=$IMAGE_DIR_TOP"
	echo "IMAGE_NAME=$IMAGE_NAME"

	if [ ! -e ${IMAGE_DIR_TOP} ];then
			mkdir -p ${IMAGE_DIR_TOP}
	fi

	echo -n > ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt
	echo "UFS_GEAR_RATE=${UFS_GEAR_RATE}" >> ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt
	echo "UFS_WB_FORCE_DISABLE=${UFS_WB_FORCE_DISABLE}" >> ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt
	echo "UFS_FLUSH_DURING_HIBERNATE_ENABLE_FORCE_ON=${UFS_FLUSH_DURING_HIBERNATE_ENABLE_FORCE_ON}" >> ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt
	echo "UFS_FORCE_BKOPS_DISABLE=${UFS_FORCE_BKOPS_DISABLE}" >> ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt
	echo "UFS_FUA1=${UFS_FUA1}" >> ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt
	echo "UFS_CP1=${UFS_CP1}" >> ${IMAGE_ORIGINAL_DIR}/ENV_VAL.txt

	echo "IMAGE_ORIGINAL_DIR=${IMAGE_ORIGINAL_DIR}"
	echo "IMAGE_DIR_TOP/IMAGE_NAME=${IMAGE_DIR_TOP}/${IMAGE_NAME}"
	mv ${IMAGE_ORIGINAL_DIR} ${IMAGE_DIR_TOP}/${IMAGE_NAME}


#圧縮ファイルを作成する場合
	if [ ${COMPRESS_PATTERN} -eq 1 ]; then
		CUR_DIR=`pwd`

		IMAGE_DIR_CURRENT="${IMAGE_DIR_BASE}/${IMAGE_DIR_TOP}"
		COMPRESS_DIR="compress_image/${IMAGE_DIR_CURRENT}"

		mkdir -p ${COMPRESS_DIR}

		cd ${IMAGE_DIR_TOP}

		7z a ${CUR_DIR}/${COMPRESS_DIR}/${IMAGE_NAME}.7z ${IMAGE_NAME}

		cd $CUR_DIR
	fi
	ls

date

echo ""
echo "********************************************************"
echo "****                                                ****"
echo "****         create image complete !!!!!!!!         ****"
echo "****                                                ****"
echo "********************************************************"
echo "image dir ${IMAGE_DIR_TOP}/${IMAGE_NAME}"

