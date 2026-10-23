// 强制更新窗口与主进程之间的桥（contextIsolation 下唯一通道）。
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('dshForce', {
  data: () => ipcRenderer.sendSync('force-data'),
  upgrade: () => ipcRenderer.send('force-upgrade'),
  quit: () => ipcRenderer.send('force-quit'),
})
