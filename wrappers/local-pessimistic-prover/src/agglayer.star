constants = import_module("../../../src/package_io/constants.star")
databases_package = import_module("../../../src/chain/shared/databases.star")


def run(plan, deployment_stages, args, contract_setup_addresses):
    agglayer_config_artifact = create_agglayer_config_artifact(
        plan, args, contract_setup_addresses
    )
    aggregator_keystore_artifact = plan.store_service_files(
        name="aggregator-keystore",
        service_name="contracts" + args["deployment_suffix"],
        src=constants.KEYSTORES_DIR + "/aggregator.keystore",
    )

    ports = get_agglayer_ports(args)
    plan.add_service(
        name="agglayer",
        config=ServiceConfig(
            image=args["agglayer_image"],
            ports=ports,
            files={
                "/etc/agglayer": Directory(
                    artifact_names=[
                        agglayer_config_artifact,
                        aggregator_keystore_artifact,
                    ]
                ),
            },
            entrypoint=["/usr/local/bin/agglayer"],
            env_vars={
                "RUST_BACKTRACE": "1",
            },
            cmd=["run", "--cfg", "/etc/agglayer/config.toml"],
        ),
    )


def create_agglayer_config_artifact(plan, args, contract_setup_addresses):
    agglayer_config_template = read_file(src="../static_files/agglayer/config.toml")
    db_configs = databases_package.get_db_configs(
        args["deployment_suffix"], args["sequencer_type"]
    )

    return plan.render_templates(
        name="wrapper-agglayer-config",
        config={
            "config.toml": struct(
                template=agglayer_config_template,
                data={
                    "deployment_suffix": args["deployment_suffix"],
                    "log_level": args.get("log_level"),
                    "log_format": args.get("log_format"),
                    "l1_chain_id": args["l1_chain_id"],
                    "l1_rpc_url": args["mitm_rpc_url"].get(
                        "agglayer", args["l1_rpc_url"]
                    ),
                    "l1_ws_url": args["l1_ws_url"],
                    "l2_keystore_password": args["l2_keystore_password"],
                    "l2_sequencer_address": args["l2_sequencer_address"],
                    "agglayer_grpc_port": args["agglayer_grpc_port"],
                    "agglayer_readrpc_port": args["agglayer_readrpc_port"],
                    "agglayer_admin_port": args["agglayer_admin_port"],
                    "prometheus_port": args["agglayer_metrics_port"],
                    "l2_rpc_name": args["l2_rpc_name"],
                    "sequencer_type": args["sequencer_type"],
                    "op_el_rpc_url": args["op_el_rpc_url"],
                    "agglayer_cpu_prover_max_concurrency_limit": args.get(
                        "agglayer_cpu_prover_max_concurrency_limit", 1
                    ),
                    "agglayer_cpu_prover_proving_timeout": args.get(
                        "agglayer_cpu_prover_proving_timeout", "1h"
                    ),
                    "agglayer_prover_buffer_size": args.get(
                        "agglayer_prover_buffer_size", 100
                    ),
                    "input_backpressure_buffer_size": args.get(
                        "agglayer_input_backpressure_buffer_size", 1000
                    ),
                }
                | contract_setup_addresses
                | db_configs,
            )
        },
    )


def get_agglayer_ports(args):
    return {
        "aglr-grpc": PortSpec(
            args["agglayer_grpc_port"], application_protocol="grpc"
        ),
        "aglr-readrpc": PortSpec(
            args["agglayer_readrpc_port"], application_protocol="http"
        ),
        "aglr-admin": PortSpec(
            args["agglayer_admin_port"], application_protocol="http"
        ),
        "prometheus": PortSpec(
            args["agglayer_metrics_port"], application_protocol="http"
        ),
    }
