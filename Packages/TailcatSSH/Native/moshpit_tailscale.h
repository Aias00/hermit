/* Moshpit's embedded Tailscale ABI. Shares the CTailcat Go runtime and handles. */
#ifndef MOSHPIT_TAILSCALE_H
#define MOSHPIT_TAILSCALE_H
#include "tailcat.h"
#ifdef __cplusplus
extern "C" {
#endif

enum {
    MT_STORAGE_FAILURE = 7,
    MT_STATE_DECRYPT_FAILED = 8,
    MT_ALREADY_OPEN = 9,
    MT_AUTH_REQUIRED = 10,
    MT_APPROVAL_REQUIRED = 11
};

uint32_t mt_abi_version(void);

/* All calls follow tailcat.h ownership/cancellation conventions. Node and TCP
 * connection handles use tc_close; tokens use tc_token_new/cancel/close;
 * connected streams use tc_conn_read/write/readable/close_write. Strings use
 * tc_free. A node owns all its connections. Calls are synchronous; run off the
 * main/UI/NIO thread. Close may wait for resource shutdown.
 *
 * new performs local encrypted storage validation only, never network I/O.
 * config_json: {"state_directory":"absolute existing private directory",
 *               "hostname":"moshpit-iphone", "control_url":"https://..."}
 * control_url is optional (official Tailscale default). key is exactly 32 bytes
 * supplied from the OS Keychain, copied for this node's lifetime, never logged.
 * Only one live node can own a directory, including across processes.
 */
int32_t mt_node_new(char *config_json, uint8_t *key, size_t key_len,
                    tc_handle *out, char **error);

/* Restores/starts the node without initiating interactive enrollment. A missing
 * or expired login needs mt_node_start_login, even with ambient CLI auth env. */
int32_t mt_node_start(tc_handle node, tc_token token, char **error);

/* No network startup is triggered by status. Before start backend_state=Stopped.
 * schema_version=1; backend_state/auth_url/tailnet_name/user_login are strings;
 * account_identity is null or a stable nonsecret account binding string;
 * self is null or Peer; peers is an array of Peer sorted by id.
 * Peer: {id,hostname,dns_name,ips:[string],online:bool}.
 * AuthURL is a login capability: display only through browser UI, never log it.
 */
int32_t mt_node_status(tc_handle node, tc_token token, char **out, char **error);

/* Initiates browser enrollment; poll status for auth_url. Does not open a browser.
 * Calls are cancellable; completion can win a cancellation race. */
int32_t mt_node_start_login(tc_handle node, tc_token token, char **error);

/* Closes this node's streams and requests logout with the control server.
 * Failure is reported (never pretend remote revocation succeeded). Credentials
 * remain encrypted. Caller should close and remove local state for full reset. */
int32_t mt_node_logout(tc_handle node, tc_token token, char **error);

/* TCP only. Requires backend Running. No implicit interactive login.
 * host is a tailnet address/name; no direct/public network fallback is made. */
int32_t mt_node_dial(tc_handle node, tc_token token, char *host,
                    uint16_t port, tc_handle *out, char **error);

#ifdef __cplusplus
}
#endif
#endif
