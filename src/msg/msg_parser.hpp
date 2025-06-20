#ifndef _SA_MSG_MSG_PARSER_
#define _SA_MSG_MSG_PARSER_

#include "../pchheader.hpp"
#include "msg_common.hpp"
#include "../hp_manager.hpp"

namespace msg
{
    class msg_parser
    {
        jsoncons::json jdoc;

    public:
        int parse(std::string_view message);
        int extract_type(std::string &extracted_type) const;
        int extract_create_message(create_msg &msg) const;
        int extract_initiate_message(initiate_msg &msg) const;
        int extract_destroy_message(destroy_msg &msg) const;
        int extract_start_message(start_msg &msg) const;
        int extract_stop_message(stop_msg &msg) const;
        int extract_inspect_message(inspect_msg &msg) const;
        void build_response(std::string &msg, std::string_view response_type, std::string_view content, const bool json_content = false) const;
        void build_create_response(std::string &msg, const hp::instance_info &info) const;
        void build_list_response(std::string &msg,
                                             const std::vector<hp::instance_info> &instances, const std::vector<hp::lease_info> &leases) const;
        void build_inspect_response(std::string &msg, const hp::instance_info &instance) const;
        void build_error_response(std::string &msg,
                                         std::string_view container_name, std::string_view error) const;
    };

} // namespace msg

#endif