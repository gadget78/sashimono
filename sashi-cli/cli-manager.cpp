#include "pchheader.hpp"
#include "cli-manager.hpp"

namespace cli
{
    constexpr const char *SOCKET_NAME = "sa.sock";        // Name of the sashimono socket.
    constexpr const char *SAGENT_BIN_NAME = "sagent";     // Name of the sashimono agent bin.
    constexpr const char *DATA_DIR = "/etc/sashimono";    // Sashimono data directory.
    constexpr const char *BIN_DIR = "/usr/bin/sashimono"; // Sashimono bin directory.
    constexpr const int BUFFER_SIZE = 4096;               // Max read buffer size.
    constexpr const char *MSG_LIST = "{\"type\": \"list\"}";
    constexpr const char *MSG_BASIC = "{\"type\":\"%s\",\"container_name\":\"%s\"}";
    constexpr const char *MSG_CREATE = "{\"type\":\"create\",\"container_name\":\"%s\",\"owner_pubkey\":\"%s\",\"contract_id\":\"%s\",\"image\":\"%s\",\"outbound_ipv6\":\"%s\",\"outbound_net_interface\":\"%s\",\"config\":{}}";

    constexpr const char *DOCKER_ATTACH = "DOCKER_HOST=unix:///run/user/$(id -u %s)/docker.sock %s/dockerbin/docker attach --detach-keys=\"ctrl-c\" %s";

    cli_context ctx;

    bool init_success = false;

    /**
     * Initialize the socket and connect.
     * @return 0 on success, -1 on error.
     */
    int init(std::string_view sashi_dir)
    {
        ctx.sashi_dir = sashi_dir;

        // Get the socket path from available location.
        if (get_socket_path(ctx.socket_path) == -1)
            return -1;

        // Get the sashimono binary path from available location.
        if (get_bin_path(ctx.sashimono_dir) == -1)
            return -1;

        // Create the seq paket socket.
        ctx.socket_fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
        if (ctx.socket_fd == -1)
        {
            std::cerr << errno << " :Error while creating the sashimono socket.\n";
            return -1;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(struct sockaddr_un));

        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, ctx.socket_path.data(), sizeof(addr.sun_path) - 1);

        if (connect(ctx.socket_fd, (const struct sockaddr *)&addr, sizeof(struct sockaddr_un)) == -1)
        {
            // If permission denied, show a custom error.
            if (errno == EACCES)
                std::cerr << "Permission denied: Only root or users in 'sashiadmin' group can access the sashimono socket.\n";
            else
                std::cerr << errno << " :Error while connecting to the sashimono socket.\n";
            close(ctx.socket_fd);
            return -1;
        }

        init_success = true;
        return 0;
    }

    /**
     * Locate and return the sashimono agent socket path according predefined rules.
     * If sa.sock found on the same path as the cli binary, use that. (to support dev testing)
     * Else sa.sock found on /etc/sashimono, use that.
     * Else show error.
     * @param socket_path Socket path to be populated.
     * @return 0 on success, -1 on error.
     */
    int get_socket_path(std::string &socket_path)
    {
        // Check whether socket exists in exec path.
        std::string path = ctx.sashi_dir + std::string("/") + SOCKET_NAME;
        struct stat st;
        if (stat(path.data(), &st) == 0 && S_ISSOCK(st.st_mode))
        {
            socket_path = path;
            return 0;
        }

        // Otherwise check in the data dir.
        path = DATA_DIR + std::string("/") + SOCKET_NAME;
        memset(&st, 0, sizeof(struct stat));
        if (stat(path.data(), &st) == 0 && S_ISSOCK(st.st_mode))
        {
            socket_path = path;
            return 0;
        }

        std::cerr << SOCKET_NAME << " is not found.\n";
        return -1;
    }

    /**
     * Locate and return the sashimono agent binary path according predefined rules.
     * If sagent found on the same path as the binary, use that. (to support dev testing)
     * Else sagent found on /bin/sashimono, use that.
     * Else show error.
     * @param bin_path Binary path to be populated.
     * @return 0 on success, -1 on error.
     */
    int get_bin_path(std::string &bin_path)
    {
        // Check whether binary exists in exec path.
        std::string path = ctx.sashi_dir + std::string("/") + SAGENT_BIN_NAME;
        struct stat st;
        if (stat(path.data(), &st) == 0 && S_ISREG(st.st_mode))
        {
            bin_path = ctx.sashi_dir;
            return 0;
        }

        // Otherwise check in the bin dir.
        path = BIN_DIR + std::string("/") + SAGENT_BIN_NAME;
        memset(&st, 0, sizeof(struct stat));
        if (stat(path.data(), &st) == 0 && S_ISREG(st.st_mode))
        {
            bin_path = BIN_DIR;
            return 0;
        }

        std::cerr << SAGENT_BIN_NAME << " is not found.\n";
        return -1;
    }

    /**
     * Write a given message into the sashimono socket.
     * @param message Message to be write.
     * @return 0 on success, -1 on error.
     */
    int write_to_socket(std::string_view message)
    {
        if (!init_success)
        {
            std::cerr << "Sashimono socket is not initialized.\n";
            return -1;
        }

        if (write(ctx.socket_fd, message.data(), message.size()) == -1)
        {
            std::cerr << errno << " :Error while wrting to the sashimono socket.\n";
            return -1;
        }

        return 0;
    }

    /**
     * Read message from the sashimono socket.
     * @param message Message to be read.
     * @return Read message length on success, -1 on error.
     */
    int read_from_socket(std::string &message)
    {
        if (!init_success)
        {
            std::cerr << "Sashimono socket is not initialized.\n";
            return -1;
        }

        // Read the length of the message to a buffer
        uint8_t length_buffer[8];
        int res = read(ctx.socket_fd, length_buffer, 8);
        if (res == -1)
        {
            std::cerr << errno << " :Error while reading message length from the sashimono socket.\n";
            return -1;
        }

        const uint32_t message_length = uint32_from_bytes(length_buffer);

        // Resize the message buffer to fit to the message length
        message.resize(message_length);
        res = read(ctx.socket_fd, message.data(), message_length);
        if (res == -1)
        {
            std::cerr << errno << " :Error while reading the message from the sashimono socket.\n";
            return -1;
        }

        return res;
    }

    // Convert byte buffer to uint32_t
    uint32_t uint32_from_bytes(const uint8_t *data)
    {
        return ((uint32_t)data[0] << 24) +
               ((uint32_t)data[1] << 16) +
               ((uint32_t)data[2] << 8) +
               ((uint32_t)data[3]);
    }

    int get_json_output(std::string_view json_msg, std::string &output)
    {
        if (write_to_socket(json_msg) == -1 || read_from_socket(output) == -1)
            return -1;

        return 0;
    }

    int execute_basic(std::string_view type, std::string_view container_name)
    {
        std::string msg, output;
        msg.resize(31 + type.size() + container_name.size());
        sprintf(msg.data(), MSG_BASIC, type.data(), container_name.data());

        const int ret = get_json_output(msg, output);
        if (ret == 0)
            std::cout << output << std::endl;
        return ret;
    }

    int create(std::string_view container_name, std::string_view owner, std::string_view contract_id, std::string_view image, std::string_view outbound_ipv6, std::string_view outbound_net_interface)
    {
        std::string msg, output;
        msg.resize(142 + container_name.size() + owner.size() + contract_id.size() + image.size() + outbound_ipv6.size() + outbound_net_interface.size());
        sprintf(msg.data(), MSG_CREATE, container_name.data(), owner.data(), contract_id.data(), image.data(), outbound_ipv6.data(), outbound_net_interface.data());

        const int ret = get_json_output(msg, output);
        if (ret == 0)
            std::cout << output << std::endl;
        return ret;
    }

    /**
     * Print the list of instances in a tabular manner.
     * @return 0 on success, -1 on error.
     */
    int list()
    {
        std::string output;
        if (get_json_output(MSG_LIST, output) == -1)
            return -1;

        try
        {
            jsoncons::json d = jsoncons::json::parse(output, jsoncons::strict_json_parsing());
            if (!d.contains("type") ||
                d["type"].as<std::string>() != "list_res" ||
                !d.contains("content") ||
                !d["content"].is_array())
            {
                std::cerr << "Invalid response. " << jsoncons::pretty_print(d) << std::endl;
                return -1;
            }

            jsoncons::json content = d["content"];
            std::cout << jsoncons::pretty_print(content) << std::endl;
        }
        catch (const std::exception &e)
        {
            std::cerr << "JSON message parsing failed. " << e.what() << std::endl;
            return -1;
        }

        return 0;
    }

    /**
     * Execute and docker command in a givent container.
     * @param type Type of the command.
     * @param container_name Name of the contract.
     * @return 0 on success, -1 on error.
     */
    int docker_exec(std::string_view type, std::string_view container_name)
    {
        std::string msg, output;
        msg.resize(38 + container_name.size());
        sprintf(msg.data(), MSG_BASIC, "inspect", container_name.data());

        const int ret = get_json_output(msg, output);
        if (ret == -1)
        {
            std::cout << output << std::endl;
            std::cerr << "Error inspecting the container." << std::endl;
            return -1;
        }

        std::string user;
        try
        {
            jsoncons::json d = jsoncons::json::parse(output, jsoncons::strict_json_parsing());
            if (!d.contains("type") ||
                !d.contains("content") ||
                !((d["type"].as<std::string>() == "inspect_res" && d["content"].is_object()) || (d["type"].as<std::string>() == "inspect_error" && !d["content"].is_object())))
            {
                std::cerr << "Invalid inspect response. " << jsoncons::pretty_print(d) << std::endl;
                return -1;
            }

            if (d["type"].as<std::string>() == "inspect_error")
            {
                std::cerr << output << std::endl;
                return -1;
            }

            user = d["content"]["user"].as<std::string>();
        }
        catch (const std::exception &e)
        {
            std::cerr << "JSON message parsing failed. " << e.what() << std::endl;
            return -1;
        }

        if (user.empty())
        {
            std::cerr << "Invalid user." << std::endl;
            return -1;
        }

        if (type == "attach")
        {
            const int len = 75 + user.length() + ctx.sashimono_dir.length() + container_name.length();
            char command[len];
            sprintf(command, DOCKER_ATTACH, user.data(), ctx.sashimono_dir.data(), container_name.data());
            std::cout << "ctrl+C to detach." << std::endl;
            return system(command) == 0 ? 0 : -1;
        }
        else
        {
            std::cerr << "Invalid docker command type." << std::endl;
            return -1;
        }

        return 0;
    }

    void print_to_table(const jsoncons::json &list, const std::vector<std::pair<std::string, std::string>> &columns)
    {
        // Initialize column sizes to header lengths.
        std::map<std::string, size_t> col_sizes;
        for (const auto &[key, header] : columns)
            col_sizes[key] = header.size();

        for (auto &item : list.array_range())
        {
            for (const auto &[key, header] : columns)
            {
                if (item.contains(key))
                {
                    const std::string val_str = value_to_string(item[key]);
                    const size_t val_size = val_str.size();
                    if (col_sizes[key] < val_size)
                        col_sizes[key] = val_size;
                }
            }
        }

        // Print the headers.
        for (const auto &[key, header] : columns)
        {
            const std::string pad_str = ("%-" + std::to_string(col_sizes[key]) + "s  ");
            printf(pad_str.data(), header.data());
        }
        printf("\n");

        // Print the header separators.
        for (const auto &[key, header] : columns)
        {
            const std::string sep(col_sizes[key], '-');
            printf("%s  ", sep.data());
        }
        printf("\n");

        // Print the values.
        for (auto &item : list.array_range())
        {
            for (const auto &[key, header] : columns)
            {
                if (!item.contains(key))
                    continue;

                const std::string pad_str = ("%-" + std::to_string(col_sizes[key]) + "s  ");
                const std::string val_str = value_to_string(item[key]);
                printf(pad_str.data(), val_str.data());
            }
            printf("\n");
        }
    }

    const std::string value_to_string(const jsoncons::json &val)
    {
        if (val.is_uint64())
            return std::to_string(val.as<uint64_t>());
        else
            return val.as_string();
    }

    /**
     * Close the socket and deinitialize.
     */
    void deinit()
    {
        if (init_success)
            close(ctx.socket_fd);
    }
}