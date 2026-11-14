// Drive the real TypeScript extensions against a private ingress socket.
import net from "node:net"
import { pathToFileURL } from "node:url"

const pluginID = process.env.CTRLX_PLUGIN_ID
if (pluginID !== "pi" && pluginID !== "omp") {
  throw new Error("Set CTRLX_PLUGIN_ID to pi or omp for this fixture")
}
const frames = []
const nativeCalls = []
const server = net.createServer({ allowHalfOpen: true }, socket => {
  const chunks = []
  socket.on("data", chunk => chunks.push(chunk))
  socket.on("end", () => {
    const bytes = Buffer.concat(chunks)
    frames.push(JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE(0))))
    // Make concurrent sends observable, including across extension reload.
    setTimeout(() => socket.end(), 20)
  })
})
await new Promise(resolve => server.listen(process.env.CTRLX_INGRESS_SOCK, resolve))
const context = id => ({ hasUI: true, cwd: "/test", sessionManager: { getSessionId: () => id } })
const bridgeURL = pathToFileURL(process.argv[2])
async function load(suffix) {
  const { default: bridge } = await import(`${bridgeURL}?${suffix}`)
  const handlers = new Map()
  bridge({ on: (name, handler) => handlers.set(name, handler) })
  return (name, id, event = {}) => {
    nativeCalls.push(name)
    return handlers.get(name)(event, context(id))
  }
}
try {
  const first = await load("first")
  const switchEvent = pluginID === "omp" ? "session_switch" : "session_start"
  await first("session_start", "A")
  await first(switchEvent, "B", { reason: "new" })
  // Re-evaluating the extension must not reset the process's sequence or FIFO.
  const reloaded = await load("reload")
  await reloaded(switchEvent, "A", { reason: "resume" })
  await reloaded("agent_start", "A")
  await reloaded("agent_end", "A", { messages: [{ role: "assistant", stopReason: "stop", content: [{ type: "text", text: "Done" }] }] })
  await reloaded("session_shutdown", "A", { reason: "quit" })
} finally {
  await new Promise(resolve => server.close(resolve))
}
console.log(JSON.stringify({ nativeCalls, frames }))
