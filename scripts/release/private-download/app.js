"use strict";
(async () => {
  const text = (id, value) => { document.getElementById(id).textContent = value; };
  try {
    const response = await fetch("/api/release", { cache: "no-store" });
    if (!response.ok) throw new Error("release unavailable");
    const release = await response.json();
    text("version", `${release.version} (${release.build})`);
    text("signing", {development:"开发签名",distribution:"分发签名",unsigned:"需重签"}[release.signing] || "需重签");
    text("size", `${(release.size / 1024 / 1024).toFixed(1)} MB`);
    text("os", `iOS ${release.minimumOS} 及以上`);
    text("commit", release.sourceCommit.slice(0, 7));
    text("hash", release.sha256);
    if (release.profileExpiresAt) {
      const expiry = new Date(release.profileExpiresAt);
      text("expiry", expiry.toLocaleString("zh-CN", { month:"numeric",day:"numeric",hour:"2-digit",minute:"2-digit" }));
      document.getElementById("expired").hidden = expiry.getTime() > Date.now();
    } else text("expiry", "安装时重新签名");
    for (const note of release.notes) {
      const item = document.createElement("li");
      item.textContent = note;
      document.getElementById("notes").append(item);
    }
    const download = document.getElementById("download");
    download.href = "/Hermit.ipa";
    download.removeAttribute("aria-disabled");
  } catch {
    text("version", "暂时无法读取安装包");
    text("signing", "未就绪");
    text("status", "请确认私有网络连接后刷新页面。");
    document.getElementById("status").classList.add("error");
  }
})();
