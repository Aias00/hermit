#include "moshpit_tailscale.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    assert(tc_abi_version() == 1 && mt_abi_version() == 1);
    char directory[] = "/tmp/moshpit-tsnet-smoke-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    char config[1024];
    snprintf(config, sizeof(config), "{\"state_directory\":\"%s\",\"hostname\":\"moshpit-smoke\"}", directory);
    uint8_t key[32] = {0};
    tc_handle node = 0, duplicate = 0, stream = 42;
    char *error = NULL, *status = NULL;
    assert(mt_node_new(config, key, sizeof(key), &node, &error) == TC_OK);
    assert(node != 0 && error == NULL);
    assert(mt_node_status(node, TC_NO_CANCEL, &status, &error) == TC_OK);
    assert(strstr(status, "\"backend_state\":\"Stopped\"") != NULL);
    assert(strstr(status, "\"account_identity\":null") != NULL);
    tc_free(status);
    assert(mt_node_new(config, key, sizeof(key), &duplicate, &error) == MT_ALREADY_OPEN);
    assert(duplicate == 0); tc_free(error);
    assert(mt_node_dial(node, TC_NO_CANCEL, "node", 22, &stream, &error) == MT_AUTH_REQUIRED);
    assert(stream == 0); tc_free(error);
    tc_token token = 0;
    assert(tc_token_new(0, &token, &error) == TC_OK);
    assert(mt_node_start(node, token, &error) == TC_TIMEOUT); tc_free(error);
    assert(tc_close(token, &error) == TC_OK);
    assert(tc_close(node, &error) == TC_OK);
    assert(mt_node_new(config, key, sizeof(key), &node, &error) == TC_OK);
    assert(tc_close(node, &error) == TC_OK);
    snprintf(config, sizeof(config), "%s/.moshpit-tailscale.lock", directory);
    unlink(config); rmdir(directory);
    puts("Tailcat + Tailscale ABI smoke passed (offline)");
    return 0;
}
