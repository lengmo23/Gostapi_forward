## Gostapi_forward

A one-click forwarding script built on **GOST v3 API**.

### Updates

- **V1.1 (2025/11/07)** – Added basic TCP/UDP forwarding support
  
- **V1.2 (2025/11/11)** – Added **Relay protocol** forwarding support
  
- **V1.3 (2025/11/19)** – Added **LeastPing load balancing** support
  

### Installation

```
bash <(curl -fsSL https://raw.githubusercontent.com/lengmo23/Gostapi_forward/refs/heads/main/gostapi.sh)
```
🌐 Tip:
If you’re in a region where GitHub access is slow or unstable,
use the accelerated mirror below instead:
```
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/lengmo23/Gostapi_forward/refs/heads/main/gostapi.sh)
```
###### **Features**

- One-click deployment of the **GOST environment**
  
- **Web-based visual management interface**
  
- Easy **forwarding rule management**
  
- **Encrypted forwarding** via GOST Relay
  
- **Single-port multiplexing** forwarding (Relay-based)
  
- **API-based configuration** — deploy new rules without interrupting existing ones
  
- **Real-time traffic statistics** per port
  
- **Load balancing** (LeastPing, implemented externally)
  
- **Multi-server API management** (in development)
  
- ...and more
  

###

The **Relay protocol** is a GOST-specific protocol.  
With Relay, you can transmit multiple forwarding connections through a **single port**.

**Example:**  
Frontend (A) —— IX (B) —— Destination (C, D, E, F...)

You only need to deploy the following on the IX node **B**:

```
gost -L relay://:12345
```

Then, all forwarding services from frontend **A** can use:

```
gost -F relay://B:12345
```

This establishes encrypted mappings between **A and B**, enabling A→C, A→D, A→E, A→F — all through a **single port (B:12345)**.