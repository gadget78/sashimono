#include "msg_parser.hpp"
#include "json/msg_json.hpp"

namespace msg
{
    int msg_parser::parse(std::string_view message)
    {
        return json::parse_message(jdoc, message);
    }

    int msg_parser::extract_type(std::string &extracted_type) const
    {
        return json::extract_type(extracted_type, jdoc);
    }

    int msg_parser::extract_create_message(create_msg &msg) const
    {
        return json::extract_create_message(msg, jdoc);
    }

    int msg_parser::extract_initiate_message(initiate_msg &msg) const
    {
        return json::extract_initiate_message(msg, jdoc);
    }

    int msg_parser::extract_destroy_message(destroy_msg &msg) const
    {
        return json::extract_destroy_message(msg, jdoc);
    }

    int msg_parser::extract_start_message(start_msg &msg) const
    {
        return json::extract_start_message(msg, jdoc);
    }

    int msg_parser::extract_stop_message(stop_msg &msg) const
    {
        return json::extract_stop_message(msg, jdoc);
    }

    int msg_parser::extract_inspect_message(inspect_msg &msg) const
    {
        return json::extract_inspect_message(msg, jdoc);
    }

    void msg_parser::build_response(std::string &msg, std::string_view response_type, std::string_view content, const bool json_content) const
    {
        json::build_response(msg, response_type, content, json_content);
    }

    void msg_parser::build_create_response(std::string &msg, const hp::instance_info &info) const
    {
        json::build_create_response(msg, info);
    }

    void msg_parser::build_list_response(std::string &msg,
                                         const std::vector<hp::instance_info> &instances, const std::vector<hp::lease_info> &leases) const
    {
        json::build_list_response(msg, instances, leases);
    }

    void msg_parser::build_inspect_response(std::string &msg, const hp::instance_info &instance) const
    {
        json::build_inspect_response(msg, instance);
    }

    void msg_parser::build_error_response(std::string &msg,
                                         std::string_view container_name, std::string_view error) const
    {
        json::build_error_response(msg, container_name, error);
    }

} // namespace msg