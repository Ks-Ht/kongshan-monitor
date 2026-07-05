/* 服务器管理:增删改 + 批量,全部集中于此。 */
"use strict";

let NODES = [];
const SELECTED = new Set();
let INTERVAL = 5;

function isOnline(n) {
  return n.last_seen && (Date.now() / 1000 - n.last_seen <= Math.max(INTERVAL * 3, 10));
}
function statusPill(n) {
  const online = isOnline(n);
  const cls = n.registered ? (online ? "on" : "off") : "pending";
  const txt = n.registered ? (online ? "在线" : "离线") : "待注册";
  const p = el("span", "spill spill-" + cls);
  p.appendChild(el("span", "spill-dot"));
  p.appendChild(el("span", null, txt));
  return p;
}

/* 流量单元格:未启用清零显示"总计",启用后显示"本期(周期起)" */
function fmtTrafficCell(n) {
  const total = (n.traffic_rx_total || 0) + (n.traffic_tx_total || 0);
  const sum = fmtBytes(total) + "(↓" + fmtBytes(n.traffic_rx_total || 0) + " ↑" + fmtBytes(n.traffic_tx_total || 0) + ")";
  if (!n.traffic_reset_enabled) return sum;
  return sum + " · 每月 " + n.traffic_reset_day + " 日清零";
}

/* ---- 排序 ---- */
function statusRank(n) {
  if (!n.registered) return 0; // 待注册
  return isOnline(n) ? 2 : 1; // 离线=1,在线=2(降序时在线排前面)
}
const SORT_COLS = [
  { key: "name", label: "名称", get: (n) => (n.name || "").toLowerCase() },
  { key: "grp", label: "分组", get: (n) => (n.grp || "").toLowerCase() },
  { key: "note", label: "备注", get: (n) => (n.note || "").toLowerCase() },
  { key: "status", label: "状态", get: statusRank },
  { key: "host", label: "主机/系统", get: (n) => (n.hostname || "").toLowerCase() },
  { key: "agent", label: "Agent", get: (n) => n.agent_version || "" },
  { key: "traffic", label: "流量(本期)", get: (n) => (n.traffic_rx_total || 0) + (n.traffic_tx_total || 0) },
  { key: "last_seen", label: "最后上报", get: (n) => n.last_seen || 0 },
];
let sortKey = localStorage.getItem("op-srv-sort-key") || "name";
let sortDir = parseInt(localStorage.getItem("op-srv-sort-dir") || "1", 10) || 1;
function setSort(key) {
  if (sortKey === key) sortDir *= -1; else { sortKey = key; sortDir = 1; }
  localStorage.setItem("op-srv-sort-key", sortKey);
  localStorage.setItem("op-srv-sort-dir", String(sortDir));
  render();
}
function sortNodes(list) {
  const col = SORT_COLS.find((c) => c.key === sortKey) || SORT_COLS[0];
  list.sort((a, b) => {
    const av = col.get(a), bv = col.get(b);
    if (av < bv) return -1 * sortDir;
    if (av > bv) return sortDir;
    return 0;
  });
  return list;
}

function render() {
  const q = $("#search").value.trim().toLowerCase();
  let list = NODES.slice();
  if (q) list = list.filter((n) => [n.name, n.hostname, n.grp, n.os].some((s) => (s || "").toLowerCase().includes(q)));
  sortNodes(list);

  const admin = !isViewer();
  const tbl = $("#srvTbl");
  tbl.replaceChildren();
  const head = el("tr");
  if (admin) {
    const allCb = el("input"); allCb.type = "checkbox";
    allCb.checked = list.length > 0 && list.every((n) => SELECTED.has(n.id));
    allCb.addEventListener("change", () => {
      if (allCb.checked) list.forEach((n) => SELECTED.add(n.id)); else SELECTED.clear();
      render();
    });
    const th0 = el("th"); th0.appendChild(allCb); head.appendChild(th0);
  }
  SORT_COLS.forEach((c) => {
    const arrow = sortKey === c.key ? (sortDir === 1 ? " ▲" : " ▼") : "";
    const th = el("th", "th-sort", c.label + arrow);
    th.addEventListener("click", () => setSort(c.key));
    head.appendChild(th);
  });
  if (admin) head.appendChild(el("th", null, "操作"));
  tbl.appendChild(head);

  for (const n of list) {
    const tr = el("tr");
    if (admin) {
      const cbTd = el("td");
      const cb = el("input"); cb.type = "checkbox"; cb.checked = SELECTED.has(n.id);
      cb.addEventListener("change", () => { if (cb.checked) SELECTED.add(n.id); else SELECTED.delete(n.id); updateBatch(); });
      cbTd.appendChild(cb); tr.appendChild(cbTd);
    }

    const nameTd = el("td");
    const link = el("a", null, n.name); link.href = "/nodes/" + n.id; link.style.fontWeight = "600";
    nameTd.appendChild(link); tr.appendChild(nameTd);
    tr.appendChild(el("td", null, n.grp || "—"));
    tr.appendChild(el("td", "subtle", n.note || "—"));
    const stTd = el("td"); stTd.appendChild(statusPill(n)); tr.appendChild(stTd);
    tr.appendChild(el("td", "subtle", (n.hostname || "—") + (n.os ? " · " + n.os : "")));
    tr.appendChild(el("td", "subtle", n.agent_version || "—"));
    tr.appendChild(el("td", "subtle", fmtTrafficCell(n)));
    tr.appendChild(el("td", "subtle", n.last_seen ? timeAgo(n.last_seen) : "从未"));

    if (admin) {
      const ops = el("td");
      const edit = el("button", "btn ghost xs", "编辑");
      edit.addEventListener("click", () => openEdit(n));
      ops.appendChild(edit);
      if (n.registered) {
        const regen = el("button", "btn ghost xs", "重置密钥");
        regen.addEventListener("click", () => regenKey(n));
        const revoke = el("button", "btn warn xs", "吊销");
        revoke.addEventListener("click", () => revokeNode(n));
        ops.appendChild(regen); ops.appendChild(revoke);
      } else {
        const install = el("button", "btn primary xs", "一键安装");
        install.addEventListener("click", () => showInstallCmd(n));
        ops.appendChild(install);
      }
      const del = el("button", "btn danger xs", "删除");
      del.addEventListener("click", () => delNode(n));
      ops.appendChild(del);
      tr.appendChild(ops);
    }
    tbl.appendChild(tr);
  }
  if (!list.length) {
    const tr = el("tr"); const td = el("td", "subtle", NODES.length ? "无匹配" : "还没有服务器,点右上角「添加节点」");
    td.colSpan = admin ? 10 : 8; tr.appendChild(td); tbl.appendChild(tr);
  }
  updateBatch();
}

function updateBatch() {
  $("#batchbar").classList.toggle("hidden", SELECTED.size === 0);
  $("#selCount").textContent = "已选 " + SELECTED.size;
}

async function load() {
  const d = await api("GET", "/api/nodes");
  INTERVAL = d.interval || 5;
  NODES = d.nodes || [];
  // 清理已不存在的选中项
  const ids = new Set(NODES.map((n) => n.id));
  for (const id of Array.from(SELECTED)) if (!ids.has(id)) SELECTED.delete(id);
  render();
}

/* ---- 单节点操作 ---- */
let editingId = null;
function openEdit(n) {
  editingId = n.id;
  $("#eName").value = n.name; $("#eGrp").value = n.grp || ""; $("#eNote").value = n.note || "";
  $("#eTrafficReset").checked = !!n.traffic_reset_enabled;
  $("#eTrafficDay").value = n.traffic_reset_day || 1;
  $("#eTrafficDayRow").classList.toggle("hidden", !n.traffic_reset_enabled);
  $("#editMsg").textContent = "";
  $("#editDlg").showModal();
}
async function revokeNode(n) {
  if (!confirm("吊销「" + n.name + "」的 token?其 agent 将立即无法上报。")) return;
  try { await api("POST", "/api/nodes/" + n.id + "/revoke"); load(); } catch (e) { alert(e.error || "失败"); }
}
async function regenKey(n) {
  if (!confirm("重置将吊销旧 token 并生成新的一次性安装密钥,确认?")) return;
  try {
    const r = await api("POST", "/api/nodes/" + n.id + "/regen_key");
    $("#cmdDlgTitle").textContent = "新安装命令";
    $("#cmdDlgHint").textContent = "旧 token 已吊销。在目标机重新执行(30 分钟内有效):";
    $("#newCmd").textContent = r.command; $("#cmdDlg").showModal(); load();
  } catch (e) { alert(e.error || "失败"); }
}
/* 待注册节点:随时可重新取回一键安装命令(旧密钥尚未使用,直接换发新的,
   命令按当前服务端配置实时渲染,设置里改了 public_url 等也会跟着变)。 */
async function showInstallCmd(n) {
  try {
    const r = await api("POST", "/api/nodes/" + n.id + "/regen_key");
    $("#cmdDlgTitle").textContent = "一键安装命令 · " + n.name;
    $("#cmdDlgHint").textContent = "在目标服务器以 root 执行(密钥 30 分钟内有效、仅此一次显示):";
    $("#newCmd").textContent = r.command; $("#cmdDlg").showModal(); load();
  } catch (e) { alert(e.error || "失败"); }
}
async function delNode(n) {
  if (!confirm("删除「" + n.name + "」及其全部历史数据?不可恢复。")) return;
  try { await api("DELETE", "/api/nodes/" + n.id); SELECTED.delete(n.id); load(); } catch (e) { alert(e.error || "失败"); }
}

/* ---- 批量 ---- */
async function batch(action, extra) {
  const ids = Array.from(SELECTED);
  if (!ids.length) return;
  try {
    const r = await api("POST", "/api/nodes/batch", Object.assign({ action, ids }, extra || {}));
    SELECTED.clear(); await load(); alert("已处理 " + r.affected + " 个节点");
  } catch (e) { alert(e.error || "操作失败"); }
}

document.addEventListener("DOMContentLoaded", async () => {
  await myRole();
  try { await load(); } catch (e) {}
  loadAlertBadge();
  setInterval(load, 8000);

  $("#search").addEventListener("input", render);
  $("#selClear").addEventListener("click", () => { SELECTED.clear(); render(); });
  $("#batchDelete").addEventListener("click", () => { if (SELECTED.size && confirm("删除选中 " + SELECTED.size + " 个节点及历史数据?不可恢复。")) batch("delete"); });
  $("#batchRevoke").addEventListener("click", () => { if (SELECTED.size && confirm("吊销选中 " + SELECTED.size + " 个节点的 token?")) batch("revoke"); });
  $("#batchSetGrp").addEventListener("click", () => batch("set_group", { grp: $("#batchGrp").value.trim() }));

  // 编辑保存
  $("#eTrafficReset").addEventListener("change", () => {
    $("#eTrafficDayRow").classList.toggle("hidden", !$("#eTrafficReset").checked);
  });
  $("#editForm").addEventListener("submit", async (e) => {
    if (e.submitter && e.submitter.value === "cancel") return;
    e.preventDefault();
    try {
      await api("POST", "/api/nodes/" + editingId + "/rename", {
        name: $("#eName").value.trim(), grp: $("#eGrp").value.trim(), note: $("#eNote").value.trim(),
        traffic_reset_enabled: $("#eTrafficReset").checked,
        traffic_reset_day: parseInt($("#eTrafficDay").value, 10) || 1,
      });
      $("#editDlg").close(); load();
    } catch (err) { $("#editMsg").textContent = err.error || "保存失败"; }
  });

  // 添加节点
  const dlg = $("#addDlg");
  $("#nodeTrafficReset").addEventListener("change", () => {
    $("#nodeTrafficDayRow").classList.toggle("hidden", !$("#nodeTrafficReset").checked);
  });
  $("#addNodeBtn").addEventListener("click", () => {
    $("#addStep1").classList.remove("hidden"); $("#addStep2").classList.add("hidden");
    $("#nodeName").value = ""; $("#nodeGrp").value = "";
    $("#nodeTrafficReset").checked = false; $("#nodeTrafficDay").value = 1;
    $("#nodeTrafficDayRow").classList.add("hidden");
    dlg.showModal();
  });
  $("#addForm").addEventListener("submit", async (e) => {
    if (e.submitter && e.submitter.value === "cancel") return;
    if (!$("#addStep2").classList.contains("hidden")) return;
    e.preventDefault();
    const btn = $("#createBtn"); btn.disabled = true;
    try {
      const r = await api("POST", "/api/nodes", {
        name: $("#nodeName").value.trim(), grp: $("#nodeGrp").value.trim(),
        traffic_reset_enabled: $("#nodeTrafficReset").checked,
        traffic_reset_day: parseInt($("#nodeTrafficDay").value, 10) || 1,
      });
      $("#installCmd").textContent = r.command;
      $("#addStep1").classList.add("hidden"); $("#addStep2").classList.remove("hidden");
      await load();
    } catch (err) { alert(err.error || "创建失败"); } finally { btn.disabled = false; }
  });
  const copy = (sel, btn) => { navigator.clipboard.writeText($(sel).textContent).then(() => { const t = $(btn).textContent; $(btn).textContent = "已复制 ✓"; setTimeout(() => { $(btn).textContent = t; }, 1500); }).catch(() => alert("复制失败")); };
  $("#copyCmd").addEventListener("click", () => copy("#installCmd", "#copyCmd"));
  $("#copyNewCmd").addEventListener("click", () => copy("#newCmd", "#copyNewCmd"));
  $("#closeCmdDlg").addEventListener("click", () => $("#cmdDlg").close());
});

async function loadAlertBadge() {
  try { const d = await api("GET", "/api/alerts/events"); const b = $("#navBadge"); if (b) { b.textContent = String(d.firing); b.classList.toggle("hidden", !d.firing); } } catch (_) {}
}
