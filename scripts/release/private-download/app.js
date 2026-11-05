"use strict";
(async () => {
  const text = (id, value) => { document.getElementById(id).textContent = value; };
  if (location.hostname === "app.aias.eu.org") {
    text("network-hint", "通过 Cloudflare Access 验证邮箱后获取安装链接，无需开启 Tailscale。");
  }
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
    if (release.overTheAirInstall && release.installOrigin === location.origin) {
      const install = document.getElementById("install");
      let expiresAt = 0;
      let preparing = false;
      document.getElementById("install-block").hidden = false;
      document.getElementById("ota-steps").hidden = false;
      document.getElementById("download-steps").hidden = true;
      download.classList.add("secondary");
      download.lastChild.textContent = "备用：下载 IPA 安装包";
      const prepare = async () => {
        if (preparing) return;
        preparing = true;
        install.setAttribute("aria-disabled", "true");
        text("install", "正在准备安装…");
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10000);
        try {
          const result = await fetch("/api/install", {
            method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
            cache: "no-store", signal: controller.signal,
          });
          if (!result.ok) throw new Error("installation link unavailable");
          const ticket = await result.json();
          const url = new URL(ticket.installURL);
          const manifest = new URL(url.searchParams.get("url"));
          if (url.protocol !== "itms-services:" || manifest.origin !== location.origin
              || !manifest.pathname.startsWith("/ota/")) throw new Error("invalid installation link");
          install.href = ticket.installURL;
          expiresAt = ticket.expiresAt;
          install.removeAttribute("aria-disabled");
          text("install", "安装到 iPhone");
          text("status", "请用 Safari 打开，并在 iOS 弹窗中确认。开发签名仍需通过设备验证。");
        } catch {
          text("install", "重新准备安装");
          install.removeAttribute("aria-disabled");
          install.removeAttribute("href");
          text("status", "安装链接准备失败，请点击重试，或使用下方 IPA 下载。");
        } finally {
          clearTimeout(timeout);
          preparing = false;
        }
      };
      install.setAttribute("role", "button");
      install.tabIndex = 0;
      install.addEventListener("click", async event => {
        if (!install.hasAttribute("href") || Date.now() >= expiresAt - 15000) {
          event.preventDefault();
          await prepare();
          if (install.hasAttribute("href")) text("status", "链接已更新，请再次点击「安装到 iPhone」。");
        } else text("status", "已请求系统安装，请在 iOS 弹窗中确认。网页无法读取最终安装结果。");
      });
      install.addEventListener("keydown", event => {
        if (event.key === " " || event.key === "Enter" && !install.hasAttribute("href")) {
          event.preventDefault();
          install.click();
        }
      });
      await prepare();
    }
  } catch {
    text("version", "暂时无法读取安装包");
    text("signing", "未就绪");
    text("status", "请刷新页面重试；若登录已过期，请重新验证邮箱。");
    document.getElementById("status").classList.add("error");
  }
})();
