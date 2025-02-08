#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

if [ $# -eq 0 ]; then
    echo "Usage: $0 <index>"
    exit 1
fi

rshim_name="rshim$1"
pcie=$(dpumap.sh rshim2pcie $rshim_name)

if [ $? -ne 0 ]; then
    echo "Error: Invalid rshim index $1"
    exit 1
fi


if ! lspci -D | grep $pcie > /dev/null; then
    echo "PCIE device $pcie is not available"
    exit 1
fi

/usr/sbin/rshim -i $1 -d pcie-$pcie
