chrome.runtime.sendMessage({ type: "status" }).then(result => {
  document.getElementById("status").textContent = result?.status || "Откройте музыкальную вкладку и Forelock.";
}).catch(() => { document.getElementById("status").textContent = "Откройте музыкальную вкладку."; });
