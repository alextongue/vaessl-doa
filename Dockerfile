# 1) choose base container
# generally use the most recent tag

# data science notebook
# https://hub.docker.com/repository/docker/ucsdets/datascience-notebook/tags
# ARG BASE_CONTAINER=ucsdets/datascience-notebook:2020.2-stable

# scipy/machine learning (tensorflow)
# https://hub.docker.com/repository/docker/ucsdets/scipy-ml-notebook/tags

FROM ucsdets/datahub-base-notebook:2021.2-stable
#FROM ucsdets/scipy-ml-notebook:2020.2-stable

# 2) change to root to install packages
USER root

# RUN apt-get update && apt-get install -y htop byobu
# RUN yum -y install yum-utils
# RUN yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-rhel7.repo
# RUN yum clean all
# RUN yum -y install nvidia-driver-latest-dkms cuda
# RUN yum -y install cuda-drivers


# 3) install packages
COPY requirements2.yml ./
#RUN pip install --no-cache-dir -r ./requirements2.yml
RUN apt-get -y install htop
RUN conda env create --name vaessl --file=requirements2.yml
RUN conda clean -tipy
#RUN pip install --no-cache-dir networkx scipy python-louvain mmcv-full

# OOM-Killer: Disable Memory Overcommit
RUN sysctl -w vm.overcommit_memory=2
RUN sysctl -w vm.overcommit_ratio=100 

# 4) change back to notebook user
#COPY /run_jupyter.sh /
#RUN chmod 755 /run_jupyter.sh
USER $NB_UID

# Override command to disable running jupyter notebook at launch
# CMD ["/bin/bash"]