#!/bin/bash

TODAY=`date "+%Y%m%d"`
about_html="./non_HLOS/PARTNER/info/about.html"
pattern="N/A"
QCOM_REVISION_FRONT=r$(cat "$about_html" | grep "$pattern" | awk '{print $2}' | cut -d '.' -f3 | awk '{gsub(/0/,""); print}')
QCOM_REVISION_BACK=$(cat "$about_html" | grep "$pattern" | awk '{print $2}' | cut -d '.' -f4 | cut -d '<' -f1)
[ $QCOM_REVISION_BACK -gt 0 ] && QCOM_REVISION=$QCOM_REVISION_FRONT"_"$QCOM_REVISION_BACK || QCOM_REVISION=$QCOM_REVISION_FRONT

if [ "$1" == "debug" ]; then
    DIR_NAME=qfil_sm8850_${QCOM_REVISION}_ufs_debug_${TODAY}
else
    DIR_NAME=qfil_sm8850_${QCOM_REVISION}_ufs_${TODAY}
fi

echo "Copy Image START"

rm -rf $DIR_NAME
mkdir $DIR_NAME
cd $DIR_NAME

echo "."

# AOP / XBL
cp ../non_HLOS/AOP.HO.7.0/aop_proc/build/ms/bin/AAAAANAZO/kaanapali/*.mbn ./

#cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/*.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/imagefv.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/prog_firehose_ddr.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/shrm.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/uefi.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/xbl_config_devprg.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/xbl_config.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/xbl_sc.elf ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/XblRamdump.elf ./

cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/Tools/binaries/logfs_ufs_8mb.bin ./
cp ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/QcomToolsPkg/Bin/QcomTools/RELEASE/tools.fv ./

# 
cp ../non_HLOS/CPUCP.FW.1.0/cpucp_proc/kaanapali/cpucp/cpucp.elf ./
cp ../non_HLOS/CPUCP.FW.1.0/cpucp_proc/kaanapali/cpucp/cpucp_dtbs.elf ./

cp ../non_HLOS/SOCCP.FW.2.1/soccp_proc/build/ms/bin/kaanapali.soccp.prod/*.* ./
cp ../non_HLOS/PDP.FW.1.0/pdp_fw/kaanapali/pdp/*.* ./
cp ../non_HLOS/TME.FW.4.0/tme_proc/ssg_tmefwrel/release/Kaanapali/*.* ./
cp ../non_HLOS/ACPOLICY.XF.1.0/acpolicy/build/kaanapali/bin/*.* ./
echo "."

cp ../non_HLOS/DCP.FW.1.1/dcp_proc/build/ms/bin/kaanapali.dcp.prod/dcp.bin ./ 
cp ../non_HLOS/DCP.FW.1.1/dcp_proc/build/ms/bin/kaanapali.dcp.prod/dcp.mbn ./ 
cp ../non_HLOS/DCP.FW.1.1/dcp_proc/build/ms/bin/kaanapali.dcp.prod/dcp_dtb.mbn ./ 


echo "."
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/qsahara_device_programmer.xml ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/bin/*.* ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/bin/asic/*.* ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/ufs/*.* ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/ufs/bin/*.* ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/ufs/bin/asic/NON-HLOS.bin ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/build/ufs/bin/asic/sparse_images/*.* ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/config/ufs/provision/*.* ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/config/qti_misc/multi_image_qti.mbn ./
cp ../non_HLOS/Kaanapali.LA.1.0/common/core_qupv3fw/kaanapali/qupv3fw.elf ./


echo "."
# Android
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/abl.elf ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/boot.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/init_boot.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/dtbo.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/persist.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/vbmeta.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/vbmeta_system.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/qweslicstore.bin ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/recovery.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/vendor_boot.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/vendor_ramdisk.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/pvmfw.img ./
if [ "$1" == "debug" ]; then
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/super.img ./
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/userdata.img ./
fi

echo "."
cp ../non_HLOS/TZ.APPS.1.33/qtee_tas/build/ms/bin/XKWAANAT/featenabler.mbn ./
cp ../non_HLOS/TZ.APPS.1.33/qtee_tas/build/ms/bin/XKWAANAT/spu_service.mbn ./
cp ../non_HLOS/TZ.APPS.1.33/qtee_tas/build/ms/bin/XKWAANAT/uefi_sec.mbn ./
cp ../non_HLOS/TZ.APPS.1.33/qtee_tas/build/ms/bin/XKWAANAT/storsec.mbn ./
cp ../non_HLOS/TZ.APPS.1.33/qtee_tas/build/ms/bin/XKWAANAT/keymint.mbn ./
cp ../non_HLOS/TZ.APPS.1.33/qtee_tas/build/ms/bin/XKWAANAT/secretkeeper.mbn ./

echo "."
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/build/ms/bin/XKWAANAT/tz.mbn ./
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/build/ms/bin/XKWAANAT/hypvm.mbn ./
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/build/ms/bin/XKWAANAT/devcfg.mbn ./
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/build/ms/bin/XKWAANAT/tz_qti_config.mbn ./

cp ../non_HLOS/LE.VM.2.1/apps_proc/build-qti-distro-base-debug/tmp-glibc/deploy/images/trustedvm-v4/*.img ./

mv rawprogram0.xml rawprogram0_org.xml
mv rawprogram_unsparse0.xml rawprogram0.xml
mv rawprogram4.xml rawprogram4_org.xml
mv rawprogram_unsparse4.xml rawprogram4.xml

cp ../non_HLOS/PARTNER/info/about.html ./

echo "Copy Image DONE"

## DEBUG
if [ "$1" == "debug" ]; then

echo ""
echo "Copy Debug File Start"

mkdir -p Debug

echo "MataData Info"
cp ../non_HLOS/PARTNER/info/about.html ./Debug

# vmlinux
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/vmlinux ./Debug

# TZ
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/ssg/bsp/qsee/build/XKWAANAT/qsee.elf ./Debug/
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/ssg/bsp/monitor/build/XKWAANAT/mon.elf ./Debug/
cp ../non_HLOS/TZ.XF.5.33/trustzone_images/core/bsp/gunyah-hypervisor/build/XKWAANAT/oem/hypvm*.elf ./Debug/

# untripped KO 
mkdir -p ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/system_dlkm/lib/modules/* ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump/
cp ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/kernel_platform/out/msm-kernel-canoe-perf/dist/*.ko ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump/
cp -rf ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/target/product/canoe/dlkm/lib/modules/* ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump/

#cp -r ./Debug/unstripped_ko/ ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump

echo "tape archive symbols"
tar -cf ./Debug/non_HLOS.tar ./XblRamdump.elf ../non_HLOS/AOP.HO.7.0/aop_proc/core/bsp/aop/build ../non_HLOS/BOOT.MXF.2.5.3/boot_images/boot/QcomPkg/SocPkg/Kaanapali/Bin/LAA/RELEASE/XblRamdump.elf ../non_HLOS/CDSP.HT.3.2/cdsp_proc/build ../non_HLOS/LPAIDSP.HT.1.2/adsp_proc/build ../non_HLOS/TZ.XF.5.33/trustzone_images/ssg/bsp/qsee/build/XKWAANAT/qsee.elf ../non_HLOS/TZ.XF.5.33/trustzone_images/ssg/bsp/monitor/build/XKWAANAT/mon.elf ../non_HLOS/TZ.XF.5.33/trustzone_images/core/bsp/gunyah-hypervisor/build/XKWAANAT/oem/hypvm*.elf ../non_HLOS/Kaanapali.LA.1.0/contents.xml ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/*.ko ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/vmlinux ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump ../non_HLOS/LE.VM.2.1/apps_proc/build-qti-distro-base-debug/tmp-glibc/deploy/images/trustedvm-v4/

#rm -rf ./Debug/unstripped_ko
rm -rf ../non_HLOS/LA.VENDOR.16.2.0/LINUX/android/out/msm-kernel-canoe-perf/dist/unstripped_ko_dump

echo "Copy Debug File DONE"
fi
## DEBUG

