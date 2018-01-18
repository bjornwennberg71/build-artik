#!/bin/bash

set -e

TARGET_DIR=
TARGET_BOARD=
TARGET_PACKAGE=
FEDORA_NAME=
PREBUILT_RPM_DIR=
SKIP_BUILD=false
SKIP_CLEAN=false
KICKSTART_FILE=../spin-kickstarts/fedora-arm-artik.ks
KICKSTART_DIR=../spin-kickstarts
BUILDCONFIG=

print_usage()
{
	echo "-h/--help         Show help options"
	echo "-o		Target directory"
	echo "-b		Target board"
	echo "-p		Target package file"
	echo "-n		Output name"
	echo "-r		Prebuilt rpm directory"
	echo "-k		Kickstart file"
	echo "-K		Kickstart directory"
	echo "-C conf		Build configurations(If not specified, use default .fed-artik-build.conf"
	echo "--skip-build	Skip package build"
	echo "--skip-clean	Skip local repository clean-up"
	exit 0
}

parse_options()
{
	for opt in "$@"
	do
		case "$opt" in
			-h|--help)
				print_usage
				shift ;;
			-n)
				FEDORA_NAME="$2"
				shift ;;
			-o)
				TARGET_DIR=`readlink -e "$2"`
				shift ;;
			-p)
				TARGET_PACKAGE=`readlink -e "$2"`
				shift ;;
			-r)
				PREBUILT_RPM_DIR=`readlink -e "$2"`
				shift ;;
			-k)
				KICKSTART_FILE="$2"
				shift ;;
			-K)
				KICKSTART_DIR=`readlink -e "$2"`
				shift ;;
			-C)
				BUILDCONFIG=`readlink -e "$2"`
				shift ;;
			--skip-build)
				SKIP_BUILD=true
				shift ;;
			--skip-clean)
				SKIP_CLEAN=true
				shift ;;
			*)
				shift ;;
		esac
	done
}

package_check()
{
	command -v $1 >/dev/null 2>&1 || { echo >&2 "${1} not installed. Aborting."; exit 1; }
}

build_package()
{
	local pkg=$1

	pushd ../$pkg
	echo "Build $pkg.."
	fed-artik-build $BUILD_CONF
	popd
}

package_check fed-artik-creator

parse_options "$@"

if [ "$BUILDCONFIG" != "" ]; then
	BUILD_CONF="-C $BUILDCONFIG"
else
	BUILD_CONF=""
fi

if ! $SKIP_CLEAN; then
	echo "Clean up local repository..."
	fed-artik-build $BUILD_CONF --clean-repos-and-exit
fi

if [ "$PREBUILT_RPM_DIR" != "" ]; then
	echo "Copy prebuilt rpms into prebuilt directory"
	fed-artik-creator $BUILD_CONF --copy-rpm-dir $PREBUILT_RPM_DIR
fi

if ! $SKIP_BUILD; then
	FEDORA_PACKAGES=`cat $TARGET_PACKAGE`

	for pkg in $FEDORA_PACKAGES
	do
		build_package $pkg
	done
fi

fed-artik-creator $BUILD_CONF --copy-rpm-dir $KICKSTART_DIR/prebuilt

if [ "$FEDORA_NAME" == "" ]; then
	KS_BASE=${KICKSTART_FILE##*/}
	FEDORA_NAME=${KS_BASE%.*}-`date +"%Y%m%d%H%M%S"`
fi

fed-artik-creator $BUILD_CONF --copy-kickstart-dir $KICKSTART_DIR \
	--ks-file $KICKSTART_DIR/$KICKSTART_FILE -o $TARGET_DIR \
	--output-file $FEDORA_NAME

cat > $TARGET_DIR/install_sysroot.sh << __EOF__
#!/bin/sh

uudecode \$0
read -r -p "Install Path: " INSTALL_PATH
export INSTALL_PATH=\$(readlink -f "\$INSTALL_PATH")
mkdir -p \$INSTALL_PATH/BUILDROOT
sudo tar zxf $FEDORA_NAME.tar.gz -C \$INSTALL_PATH/BUILDROOT
sudo rm -f $FEDORA_NAME.tar.gz

cat > \$INSTALL_PATH/sysroot_env << __EOF__
export PATH=:$PATH
export PKG_CONFIG_SYSROOT_DIR=\$INSTALL_PATH/BUILDROOT
export PKG_CONFIG_PATH=\$INSTALL_PATH/BUILDROOT/usr/lib/pkgconfig:\$INSTALL_PATH/BUILDROOT/usr/share/pkgconfig
export CC="arm-linux-gnueabihf-gcc --sysroot=\$INSTALL_PATH/BUILDROOT"
export LD="arm-linux-gnueabihf-ld --sysroot=\$INSTALL_PATH/BUILDROOT"
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
IN__EOF__

echo "Sysroot in extracted on \$INSTALL_PATH/sysroot_env\""
echo "Please run \"source \$INSTALL_PATH/sysroot_env\" before compile."

exit
__EOF__

sed -i -e "s/IN__EOF__/__EOF__/g" $TARGET_DIR/install_sysroot.sh

uuencode $TARGET_DIR/$FEDORA_NAME.tar.gz $FEDORA_NAME.tar.gz >> $TARGET_DIR/install_sysroot.sh
chmod 755 $TARGET_DIR/install_sysroot.sh

echo "A new fedora image for sysroot has been created"
