# Gostapi_forward

基于GOSTV3 API打造的一键转发脚本。

### 更新

V1.1 2025/11/07 支持简单TCP/UDP转发

V1.2 2025/11/11 加入Relay协议转发支持

### 安装

```
bash <(curl -fsSL https://raw.githubusercontent.com/lengmo23/Gostapi_forward/refs/heads/main/gostapi.sh)
```

### **介绍**

- 一键部署 gost环境
- 可视化管理界面
- 转发规则管理
- 加密转发（Gost Relay）
- 单端口复用转发* Relay
- GOST API形式创建，部署不中断其他规则连接
- 实时端口流量统计
- 负载均衡（开发中）
- 多服务器API管理（画饼）
- ...

### 说明

Relay协议是gost特有的协议，借助relay协议，我们可以实现单端口传输多条转发：

例： 前置(A)——IX(B)——落地(C,D,E,F...)

仅需在IX机B部署`gost -L relay://:12345`

前置A的所有转发服务均可以通过`gost -F relay://B:12345`建立A和B的加密转发映射，实现A——C，A——D，A——E，A——F（仅借助B:12345单个端口）
