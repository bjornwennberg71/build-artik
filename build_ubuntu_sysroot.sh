#!/bin/bash

set -e

TARGET_PACKAGE=
BUILDCONFIG=
ARCH=armhf
SBUILD_CONF=~/.sbuildrc
DEST_DIR=
PORT=
SKIP_BUILD=false
PREBUILT_DIR=
IMG_DIR=
UBUNTU_NAME=
PREBUILT_REPO_DIR=
USE_ARTIK_REPO=false

print_usage()
{
	echo "-h/--help         Show help options"
	echo "-p|--package	Target package file"
	echo "-A|--arch		Target architecture(ex: armhf, arm64)"
	echo "--chroot		Chroot name"
	echo "-C|--sbuild-conf	Sbuild configuration path"
	echo "-D|--dest-dir	Build output directory"
	echo "-s|--server-port	Server port"
	echo "--skip-build	Skip package build"
	echo "--prebuilt-dir	Skip package build"
	echo "--use-prebuilt-repo	Use prebuilt repository"
	echo "--img-dir		Image generation directory"
	echo "-n|--ubuntu-name	Ubuntu image name"
	echo "--use-artik-repo  Use repo.artik.cloud repository"
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
			-A|--arch)
				ARCH="$2"
				shift ;;
			-p|--package)
				TARGET_PACKAGE=`readlink -e "$2"`
				shift ;;
			--chroot)
				CHROOT="$2"
				shift ;;
			-C|--sbuild-conf)
				SBUILD_CONF=`readlink -e "$2"`
				shift ;;
			-D|--dest-dir)
				DEST_DIR=`readlink -e "$2"`
				shift ;;
			-s|--server-port)
				PORT="$2"
				shift ;;
			--skip-build)
				SKIP_BUILD=true
				shift ;;
			--prebuilt-dir)
				PREBUILT_DIR=`readlink -e "$2"`
				shift ;;
			--use-prebuilt-repo)
				PREBUILT_REPO_DIR=`readlink -e "$2"`
				shift ;;
			--img-dir)
				IMG_DIR=`readlink -e "$2"`
				shift ;;
			-n|--ubuntu-name)
				UBUNTU_NAME="$2"
				shift ;;
			--use-artik-repo)
				USE_ARTIK_REPO=true
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

gen_ubuntu_meta()
{
	where=$(readlink -e $1)
	origin=$2
	label=$3

	pushd $where
	apt-ftparchive sources . \
		| tee "$where"/Sources \
		| gzip -9 > "$where"/Sources.gz

	apt-ftparchive packages "$where" \
		| sed "s@$where@@" \
		| tee "$where"/Packages \
		| gzip -9 > "$where"/Packages.gz

	# sponge comes from moreutils
	apt-ftparchive \
		-o"APT::FTPArchive::Release::Origin=$origin" \
		-o"APT::FTPArchive::Release::Label=$label" \
		-o"APT::FTPArchive::Release::Codename=$where" release "$where" \
		| sponge "$where"/Release
	popd
}

move_build_output()
{
	where=$(readlink -e $1)
	set +e
	mv *.build *.changes *.dsc *.deb *.ddeb *.tar.* *.udeb $where
}

start_local_server()
{
	where=$(readlink -e $1)
	port=$2

	pushd $where
	gen_ubuntu_meta $where artik-local repo
	python3 -m http.server $port --bind 127.0.0.1&
	SERVER_PID=$!
	popd
}

stop_local_server()
{
	kill -9 $SERVER_PID
}

build_package()
{
	local pkg=$1
	local dest_dir=$2
	if [ "$JOBS" == "" ]; then
		JOBS=`getconf _NPROCESSORS_ONLN`
	fi

	if [ -d $pkg ]; then
		debian_dir=`find ./$pkg -name "debian" -type d`
		if [ -d $debian_dir ]; then
			pushd $debian_dir/../
			echo "Build $pkg.."
			SBUILD_CONFIG=$SBUILD_CONF sbuild --chroot $CHROOT \
				--host $ARCH \
				--extra-repository="deb [trusted=yes] http://localhost:$PORT ./" \
				--anything-failed-commands="touch $dest_dir/.build_failed" \
				-j$JOBS
			popd
			move_build_output $dest_dir
			gen_ubuntu_meta $dest_dir artik-local repo
			if [ -e $dest_dir/.build_failed ]; then
				abnormal_exit
				exit -1
			fi
		fi
	fi
}

abnormal_exit()
{
	if [ "$SERVER_PID" != "" ]; then
		kill -9 $SERVER_PID
	fi
	if [ -e "${DEST_DIR}/debs/.build_failed" ]; then
		rm -f $DEST_DIR/debs/.build_failed
	fi
}

find_unused_port()
{
	read LOWERPORT UPPERPORT < /proc/sys/net/ipv4/ip_local_port_range
	while :
	do
		PORT="`shuf -i $LOWERPORT-$UPPERPORT -n 1`"
		ss -lpn | grep -q ":$PORT " || break
	done
}

trap abnormal_exit INT ERR

package_check sbuild sponge python3

parse_options "$@"

if [ "$PORT" == "" ]; then
	find_unused_port
fi

[ -d $DEST_DIR/debs ] || mkdir -p $DEST_DIR/debs

if [ "$PREBUILT_REPO_DIR" != "" ]; then
	cp -rf $PREBUILT_REPO_DIR/* $DEST_DIR/debs
fi

start_local_server $DEST_DIR/debs $PORT

pushd ../

if ! $SKIP_BUILD; then
	UBUNTU_PACKAGES=`cat $TARGET_PACKAGE`

	for pkg in $UBUNTU_PACKAGES
	do
		build_package $pkg $DEST_DIR/debs
	done
fi

popd

if [ "$PREBUILT_DIR" != "" ]; then
	echo "Copy prebuilt packages"
	cp -f $PREBUILT_DIR/*.deb $DEST_DIR/debs
	gen_ubuntu_meta $DEST_DIR/debs artik-local repo
fi

if [ "$IMG_DIR" != "" ]; then
	echo "An ubuntu image generation starting..."
	pushd $IMG_DIR
	make clean
	USE_ARTIK_REPO=$USE_ARTIK_REPO PORT=$PORT ./configure
	make IMAGEPREFIX=$UBUNTU_NAME
	mv $UBUNTU_NAME* $DEST_DIR
fi

stop_local_server

cat > $DEST_DIR/install_sysroot.sh << __EOF__
#!/bin/sh

uudecode \$0
read -r -p "Install Path: " INSTALL_PATH
export INSTALL_PATH=\$(readlink -f "\$INSTALL_PATH")
mkdir -p \$INSTALL_PATH/BUILDROOT
sudo tar zxf $UBUNTU_NAME.tar.gz -C \$INSTALL_PATH/BUILDROOT
sudo rm -f $UBUNTU_NAME.tar.gz
__EOF__

if [ "$ARCH" == "arm" -o "$ARCH" == "armhf" ]; then
cat >> $DEST_DIR/install_sysroot.sh << __EOF__
cat > \$INSTALL_PATH/sysroot_env << __EOF__
export PATH=:$PATH
export PKG_CONFIG_SYSROOT_DIR=\$INSTALL_PATH/BUILDROOT
export PKG_CONFIG_PATH=\$INSTALL_PATH/BUILDROOT/usr/lib/pkgconfig:\$INSTALL_PATH/BUILDROOT/usr/share/pkgconfig:\$INSTALL_PATH/BUILDROOT/usr/lib/arm-linux-gnueabihf/pkgconfig
export CC="arm-linux-gnueabihf-gcc --sysroot=\$INSTALL_PATH/BUILDROOT"
export LD="arm-linux-gnueabihf-ld --sysroot=\$INSTALL_PATH/BUILDROOT"
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
IN__EOF__

echo "Sysroot in extracted on \$INSTALL_PATH/sysroot_env\""
echo "Please run \"source \$INSTALL_PATH/sysroot_env\" before compile."

exit
__EOF__
elif [ "$ARCH" == "aarch64" -o "$ARCH" == "arm64" ]; then
cat >> $DEST_DIR/install_sysroot.sh << __EOF__
cat > \$INSTALL_PATH/sysroot_env << __EOF__
export PATH=:$PATH
export PKG_CONFIG_SYSROOT_DIR=\$INSTALL_PATH/BUILDROOT
export PKG_CONFIG_PATH=\$INSTALL_PATH/BUILDROOT/usr/lib/pkgconfig:\$INSTALL_PATH/BUILDROOT/usr/share/pkgconfig:\$INSTALL_PATH/BUILDROOT/usr/lib/aarch64-linux-gnu/pkgconfig
export CC="aarch64-linux-gnu-gcc --sysroot=\$INSTALL_PATH/BUILDROOT"
export LD="aarch64-linux-gnu-ld --sysroot=\$INSTALL_PATH/BUILDROOT"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
IN__EOF__

echo "Sysroot in extracted on \$INSTALL_PATH/sysroot_env\""
echo "Please run \"source \$INSTALL_PATH/sysroot_env\" before compile."

exit
__EOF__
fi

sed -i -e "s/IN__EOF__/__EOF__/g" $DEST_DIR/install_sysroot.sh

uuencode $DEST_DIR/$UBUNTU_NAME.tar.gz $UBUNTU_NAME.tar.gz >> $DEST_DIR/install_sysroot.sh
chmod 755 $DEST_DIR/install_sysroot.sh


echo "A new Ubuntu sysroot has been created"
