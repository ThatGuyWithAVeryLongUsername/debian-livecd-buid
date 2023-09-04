#!/usr/bin/env bash
# Использование: buildimage.sh BUILD-ID config.json
# Вывод:
#       /tmp/build-LiveCD-$buildID/liveCD-'$buildID'.iso' - образ с LiveCD
#       ./buildstatus-$buildID.json

# Exit codes:
# Буду отталкиваться от этой статьи: https://www.redhat.com/sysadmin/exit-codes-demystified
# exit 0    - Успех, все собралось и отработало нормально
# exit 1    - Общие ошибки
# exit 2    - Некорректный ввод 


# ПЕРЕМЕННЫЕ
# ID сборки, будет использоваться в chroot и hostname 
buildID=$1
# Конфигурационный JSON. Пока будем брать оттуда только список пакетов, может что-то еще придумаю.
cfgFile=$2

# Пароль для рута, пускай генерируется случайно
rootPw=$(openssl rand -base64 12)
# Директория для сборки
buildDir=/tmp/build-LiveCD-$buildID

# ФУНКЦИИ

# Проверка на рута
# Сделал через whoami, т.к sudo echo $EUID возвращает id пользователя, запускающего через sudo
checkRoot () {
  if [ $(whoami) != root ]
  then
    echo "Скрипт "$0" должен исполняться от имени суперпользователя."
    exit 1
  fi
}

# Проверка ввода: проверяем, что нам передали ID сборки и конфигурационный файл
# Проверяем наличие двух переменных, если неуспех - сигнализируем. "! -z " = "не равно нулю"
checkInput () {
  ([ ! -z $1 ] && [ ! -z $2 ]) || (echo "Отсутвует ID-сборки и/или конфигурационный файл" & exit 2)
}

# Разбор $cfgFile. Пихнул в функцию, чтоб запускать если выполняются условия по руту и вводу
# TODO: Придумать решение элегантнее
parseInputJSON () {
# Архитектура
  cfgFileArch=$(jq -r ".arch" $cfgFile)
# Вариант
  cfgFileVariant=$(jq -r ".variant" $cfgFile)
# Кодовое имя дистрибутива
  cfgFileSystem=$(jq -r ".system" $cfgFile)
# Репозиторий, из которого будем производить сборку
  cfgFileMirror=$(jq -r ".mirror" $cfgFile)
# Список пакетов
  cfgFilePackages=$(jq -cr ".packages[]" $cfgFile | tr '\n' ' ')
}

# Отправка уведомлений в syslog.
# Приоритет должен указываться в формате logger, т.е notice/warning/error, facility - user
# Пример:sendToSyslog warning "Обратите внимание!"
sendToSyslog () {
  logger -i --tag "buildLiveCD" --priority "user."$1 $2
}
# Сигнализируем о ошибке: отправляем сообщение о ошибке и выходим со статусом 1 
# Не придумал как красивее сообщать о ошибке, пускай пока будет эхо в консоль и сообщение в сислог с указанием шага и номером строки
echoError () {
  local errorMsg="Line "$1": Error while running script"
  echo $errorMsg
  sendToSyslog error "$errorMsg"
  exit 1
}


# Сам скрипт
# Проверка на рута
checkRoot
# Проверка ввода 
checkInput $buildID $cfgFile
# Парсим JSON
parseInputJSON

# Засекаем время начала работы скрипта
buildStartTime=$(date +"%F %T") 

# Далее интерпретация вот этой статьи: https://www.willhaley.com/blog/custom-debian-live-environment/
# Создаем в tmpfs директорию для сборки. Т.к tmpfs находится в ОЗУ то все должно быть быстрее, чем на диске.
mkdir $buildDir || echoError 87

# debootstrap: создание базовой системы Debian
debootstrap --arch=$cfgFileArch --variant=$cfgFileVariant $cfgFileSystem $buildDir/chroot $cfgFileMirror ||errorMsg 90

# CHROOT START
# Костыль: кладем сборочный скрипт в chroot. Я не разобрался как одновременно передать и переменные и шаги для запуска
cat <<EOF > $buildDir/chroot/build.sh

# Присваиваем хостнейму ID сборки
echo debian-live-$buildID > /etc/hostname

# Установка самой базы, достаточной для загрузки: ядро, systemd и live-boot
apt update && \
apt install -y --no-install-recommends linux-image-$cfgFileArch live-boot systemd-sysv

# Установка пакетов из массива packages в $cfgFile. Тут указываем все остальные пакеты
apt install -y $cfgFilePackages

# Passwd: задаем пароль для рута на 12 символов
echo "root:"$rootPw | chpasswd

# Удаляем build.sh, чтоб он не оказался в собранном образе
rm /build.sh
exit
EOF

# Делаем chroot в tmpfs:
chroot $buildDir/chroot /bin/bash -c 'sh /build.sh' || echoError 115

# mksquashfs: готовим файловую систему для загрузочного образа
mkdir -p $buildDir/{staging/{EFI/BOOT,boot/grub/x86_64-efi,isolinux,live},tmp} || echoError 118

# Упаковываем созданную в chroot среду
mksquashfs \
  $buildDir/chroot \
  $buildDir/staging/live/filesystem.squashfs \
  -e boot || echoError 124

# Копируем initramfs'ы
cp $buildDir/chroot/boot/vmlinuz-* \
    $buildDir/staging/live/vmlinuz || echoError 128
cp $buildDir/chroot/boot/initrd.img-* \
    $buildDir/staging/live/initrd || echoError 130

# Подготавливаем меню загрузчика:
# Legacy-режим
cat <<'EOF' > $buildDir/staging/isolinux/isolinux.cfg 
UI vesamenu.c32

MENU TITLE Boot Menu
DEFAULT linux
TIMEOUT 600
MENU RESOLUTION 640 480
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL linux
  MENU LABEL Debian Live [BIOS/ISOLINUX]
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live

LABEL linux
  MENU LABEL Debian Live [BIOS/ISOLINUX] (nomodeset)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live nomodeset
EOF

# UEFI
cat <<'EOF' > $buildDir/staging/boot/grub/grub.cfg
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660

insmod all_video
insmod font

set default="0"
set timeout=30

# If X has issues finding screens, experiment with/without nomodeset.

menuentry "Debian Live [EFI/GRUB]" {
    search --no-floppy --set=root --label DEBLIVE
    linux ($root)/live/vmlinuz boot=live
    initrd ($root)/live/initrd
}

menuentry "Debian Live [EFI/GRUB] (nomodeset)" {
    search --no-floppy --set=root --label DEBLIVE
    linux ($root)/live/vmlinuz boot=live nomodeset
    initrd ($root)/live/initrd
}
EOF

# UEFI: Копируем grub.cfg в директорию с загрузчиком EFI
cp $buildDir/staging/boot/grub/grub.cfg $buildDir/staging/EFI/BOOT/ 

# Третий конфиг grub, не разобрался в назначении
cat <<'EOF' > $buildDir/tmp/grub-embed.cfg
if ! [ -d "$cmdpath" ]; then
    # On some firmware, GRUB has a wrong cmdpath when booted from an optical disc.
    # https://gitlab.archlinux.org/archlinux/archiso/-/issues/183
    if regexp --set=1:isodevice '^(\([^)]+\))\/?[Ee][Ff][Ii]\/[Bb][Oo][Oo][Tt]\/?$' "$cmdpath"; then
        cmdpath="${isodevice}/EFI/BOOT"
    fi
fi
configfile "${cmdpath}/grub.cfg"
EOF

# LEGACY: Копируем загрузчик в $buildDir
cp /usr/lib/ISOLINUX/isolinux.bin $buildDir/staging/isolinux/ && \
cp /usr/lib/syslinux/modules/bios/* $buildDir/staging/isolinux/

# UEFI: Копируем загрузчик в $buildDir
cp -r /usr/lib/grub/x86_64-efi/* $buildDir/staging/boot/grub/x86_64-efi/

# UEFI: генерируем загрузчик
# для 32-битного UEFI
grub-mkstandalone -O i386-efi \
    --modules="part_gpt part_msdos fat iso9660" \
    --locales="" \
    --themes="" \
    --fonts="" \
    --output="$buildDir/staging/EFI/BOOT/BOOTIA32.EFI" \
    "boot/grub/grub.cfg=$buildDir/tmp/grub-embed.cfg"
# для 64-битного
grub-mkstandalone -O x86_64-efi \
    --modules="part_gpt part_msdos fat iso9660" \
    --locales="" \
    --themes="" \
    --fonts="" \
    --output="$buildDir/staging/EFI/BOOT/BOOTx64.EFI" \
    "boot/grub/grub.cfg=$buildDir/tmp/grub-embed.cfg"

# UEFI: Создаем образ загрузчика
(cd $buildDir/staging && \
    dd if=/dev/zero of=efiboot.img bs=1M count=20 && \
    mkfs.vfat efiboot.img && \
    mmd -i efiboot.img ::/EFI ::/EFI/BOOT && \
    mcopy -vi efiboot.img \
        $buildDir/staging/EFI/BOOT/BOOTIA32.EFI \
        $buildDir/staging/EFI/BOOT/BOOTx64.EFI \
        $buildDir/staging/boot/grub/grub.cfg \
        ::/EFI/BOOT/
)

# Создаем диск
xorriso \
    -as mkisofs \
    -iso-level 3 \
    -o "$buildDir/liveCD-$buildID.iso" \
    -full-iso9660-filenames \
    -volid "LiveCD"-$buildID \
    --mbr-force-bootable -partition_offset 16 \
    -joliet -joliet-long -rational-rock \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot \
        isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog isolinux/isolinux.cat \
    -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B $buildDir/staging/efiboot.img \
    "$buildDir/staging" || echoError 265

# Засекаем время начала конца сборки
buildEndTime=$(date +"%F %T") 
# Считаем md5 сумму образа
buildChecksum=$(md5sum $buildDir'/liveCD-'$buildID'.iso' | awk '{print $1}')

# Генерируем buildstatus-$buildID.json
jq -n --arg startTime "$buildStartTime" \
      --arg endTime "$buildEndTime" \
      --arg buildID "$buildID"\
      --arg root_password "$rootPw" \
      --arg md5sum "$buildChecksum" \
      '$ARGS.named' > 'buildstatus-'$buildID'.json'

sendToSyslog notice "Image for "$buildID" build successfully"
exit 0
