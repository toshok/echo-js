set -ex
sudo apt-add-repository -y ppa:ubuntu-toolchain-r/test
#wget -O - http://llvm.org/apt/llvm-snapshot.gpg.key|sudo apt-key add -
sudo apt-get update
sudo apt-get install libunwind7-dev make autoconf automake libedit-dev zlib1g-dev cmake
#sudo update-alternatives --install /usr/bin/gcc      gcc /usr/bin/gcc-4.9 10
#sudo update-alternatives --install /usr/bin/g++      g++ /usr/bin/g++-4.9 10
