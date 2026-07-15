FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash-completion \
    ca-certificates \
    curl \
    gnupg2 \
    lsb-release \
  && curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu focal main" \
    >/etc/apt/sources.list.d/ros1.list \
  && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash-completion \
    build-essential \
    cmake \
    coreutils \
    dbus-x11 \
    git \
    iputils-ping \
    less \
    libatlas-base-dev \
    libboost-thread-dev \
    libeigen3-dev \
    libfmt-dev \
    libgflags-dev \
    libgl1-mesa-dri \
    libgl1-mesa-glx \
    libglu1-mesa \
    libgoogle-glog-dev \
    libgoogle-glog0v5 \
    libopencv-calib3d4.2 \
    libopencv-core4.2 \
    libopencv-features2d4.2 \
    libopencv-highgui4.2 \
    libopencv-imgcodecs4.2 \
    libopencv-imgproc4.2 \
    libopencv-video4.2 \
    libpcl-common1.10 \
    libpcl-dev \
    libpcl-features1.10 \
    libpcl-filters1.10 \
    libpcl-kdtree1.10 \
    libpcl-search1.10 \
    libpcl-segmentation1.10 \
    libqt5gui5 \
    libsuitesparse-dev \
    libtbb-dev \
    libtbb2 \
    libx11-6 \
    libx11-dev \
    libxau6 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-render-util0 \
    libxcb-xinerama0 \
    libxcb-xinput0 \
    libxext-dev \
    libxkbcommon-x11-0 \
    libxt-dev \
    mesa-utils \
    nano \
    ncurses-bin \
    net-tools \
    patchelf \
    procps \
    python3-catkin-tools \
    python3-lz4 \
    ros-noetic-cv-bridge \
    ros-noetic-geometry-msgs \
    ros-noetic-image-transport \
    ros-noetic-image-transport-plugins \
    ros-noetic-message-generation \
    ros-noetic-nav-msgs \
    ros-noetic-nodelet \
    ros-noetic-pcl-conversions \
    ros-noetic-pcl-ros \
    ros-noetic-rosbag \
    ros-noetic-roscpp \
    ros-noetic-rospy \
    ros-noetic-rviz \
    ros-noetic-sensor-msgs \
    ros-noetic-sophus \
    ros-noetic-std-msgs \
    ros-noetic-tf \
    vim-tiny \
    wget \
    xauth \
  && rm -rf /var/lib/apt/lists/*

ARG CERES_VERSION=2.1.0
ARG YAML_CPP_VERSION=0.8.0
ARG BUILD_JOBS=4

RUN git clone --branch "${CERES_VERSION}" --depth 1 https://github.com/ceres-solver/ceres-solver.git /tmp/ceres \
  && cmake -S /tmp/ceres -B /tmp/ceres/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG" \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DMINIGLOG=OFF \
  && cmake --build /tmp/ceres/build --target install -- -j"${BUILD_JOBS}" \
  && git clone --branch "${YAML_CPP_VERSION}" --depth 1 https://github.com/jbeder/yaml-cpp.git /tmp/yaml-cpp \
  && cmake -S /tmp/yaml-cpp -B /tmp/yaml-cpp/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG" \
    -DBUILD_SHARED_LIBS=ON \
    -DYAML_CPP_BUILD_CONTRIB=OFF \
    -DYAML_CPP_BUILD_TESTS=OFF \
    -DYAML_CPP_BUILD_TOOLS=OFF \
  && cmake --build /tmp/yaml-cpp/build --target install -- -j"${BUILD_JOBS}" \
  && ldconfig \
  && rm -rf /tmp/ceres /tmp/yaml-cpp

RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-noetic-rosservice \
    ros-noetic-std-srvs \
  && rm -rf /var/lib/apt/lists/*

ENV TERM=xterm-256color
ENV ROS_MASTER_URI=http://127.0.0.1:11311
ENV ROS_HOSTNAME=127.0.0.1
ENV QT_X11_NO_MITSHM=1
ENV LIBGL_ALWAYS_SOFTWARE=1
ENV XDG_RUNTIME_DIR=/tmp/rviz-runtime-root
ENV PATH=/opt/ros/noetic/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PYTHONPATH=/opt/ros/noetic/lib/python3/dist-packages
ENV LD_LIBRARY_PATH=/opt/ultrafusion/lib:/opt/ros/noetic/lib:/usr/local/lib
ENV ROS_PACKAGE_PATH=/opt/ultrafusion:/opt/ros/noetic/share

RUN echo 'source /opt/ros/noetic/setup.bash' >/etc/profile.d/ros-noetic.sh \
  && echo 'source /opt/ros/noetic/setup.bash' >>/root/.bashrc \
  && mkdir -p /tmp/rviz-runtime-root \
  && chmod 700 /tmp/rviz-runtime-root

CMD ["/bin/bash"]
