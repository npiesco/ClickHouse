#pragma once

#include "config.h"

#if USE_AWS_S3

#    include <Common/logger_useful.h>

#    include <Columns/ColumnString.h>
#    include <Columns/ColumnTuple.h>
#    include <Columns/IColumn.h>

#    include <IO/ReadBufferFromS3.h>
#    include <IO/ReadHelpers.h>
#    include <IO/ReadSettings.h>
#    include <IO/S3Common.h>
#    include <Interpreters/evaluateConstantExpression.h>
#    include <Storages/NamedCollectionsHelpers.h>

#    include <Storages/ExternalDataSourceConfiguration.h>
#    include <Storages/StorageFactory.h>
#    include <Storages/StorageURL.h>
#    include <Storages/checkAndGetLiteralArgument.h>

#    include <Formats/FormatFactory.h>

#    include <aws/core/auth/AWSCredentials.h>
#    include <aws/s3/S3Client.h>
#    include <aws/s3/model/ListObjectsV2Request.h>

#    include <QueryPipeline/Pipe.h>

#    include <Storages/IStorage.h>
#    include <Storages/StorageS3.h>

#    include <unordered_map>
#    include <base/JSON.h>

namespace Aws::S3
{
class S3Client;
}

namespace DB
{

namespace ErrorCodes
{
    extern const int NUMBER_OF_ARGUMENTS_DOESNT_MATCH;
}

static const std::unordered_set<std::string_view> required_configuration_keys = {
    "url",
};
static const std::unordered_set<std::string_view> optional_configuration_keys = {
    "format",
    "compression",
    "compression_method",
    "structure",
    "access_key_id",
    "secret_access_key",
};

template <typename Name, typename MetaParser>
class IStorageDataLake : public IStorage
{
public:
    // 1. Parses internal file structure of table
    // 2. Finds out parts with latest version
    // 3. Creates url for underlying StorageS3 enigne to handle reads
    IStorageDataLake(
        const StorageS3Configuration & configuration_,
        const StorageID & table_id_,
        ColumnsDescription columns_,
        const ConstraintsDescription & constraints_,
        const String & comment,
        ContextPtr context_,
        std::optional<FormatSettings> format_settings_)
        : IStorage(table_id_)
        , base_configuration{getBaseConfiguration(configuration_)}
        , log(&Poco::Logger::get("Storage" + String(name) + "(" + table_id_.table_name + ")"))
        , table_path(base_configuration.uri.key)
    {
        StorageInMemoryMetadata storage_metadata;
        StorageS3::updateS3Configuration(context_, base_configuration);

        auto new_configuration = getAdjustedS3Configuration(context_, base_configuration, configuration_, table_path, log);

        if (columns_.empty())
        {
            columns_ = StorageS3::getTableStructureFromData(
                new_configuration, /*distributed processing*/ false, format_settings_, context_, nullptr);
            storage_metadata.setColumns(columns_);
        }
        else
            storage_metadata.setColumns(columns_);

        storage_metadata.setConstraints(constraints_);
        storage_metadata.setComment(comment);
        setInMemoryMetadata(storage_metadata);

        s3engine = std::make_shared<StorageS3>(
            new_configuration,
            table_id_,
            columns_,
            constraints_,
            comment,
            context_,
            format_settings_,
            /* distributed_processing_ */ false,
            nullptr);
    }

    static constexpr auto name = Name::name;
    String getName() const override { return name; }

    // Reads latest version of Iceberg table
    Pipe read(
        const Names & column_names,
        const StorageSnapshotPtr & storage_snapshot,
        SelectQueryInfo & query_info,
        ContextPtr context,
        QueryProcessingStage::Enum processed_stage,
        size_t max_block_size,
        size_t num_streams) override
    {
        StorageS3::updateS3Configuration(context, base_configuration);

        return s3engine->read(column_names, storage_snapshot, query_info, context, processed_stage, max_block_size, num_streams);
    }

    static ColumnsDescription getTableStructureFromData(
        const StorageS3Configuration & configuration, const std::optional<FormatSettings> & format_settings, ContextPtr ctx)
    {
        auto base_configuration = getBaseConfiguration(configuration);
        StorageS3::updateS3Configuration(ctx, base_configuration);
        auto new_configuration = getAdjustedS3Configuration(
            ctx, base_configuration, configuration, base_configuration.uri.key, &Poco::Logger::get("Storage" + String(name)));
        return StorageS3::getTableStructureFromData(
            new_configuration, /*distributed processing*/ false, format_settings, ctx, /*object_infos*/ nullptr);
    }

    static StorageS3::S3Configuration getBaseConfiguration(const StorageS3Configuration & configuration)
    {
        return {configuration.url, configuration.auth_settings, configuration.request_settings, configuration.headers};
}

    static StorageS3Configuration getAdjustedS3Configuration(
        const ContextPtr & context,
        StorageS3::S3Configuration & base_configuration,
        const StorageS3Configuration & configuration,
        const std::string & table_path,
        Poco::Logger * log)
    {
        MetaParser parser{base_configuration, table_path, context};

        auto keys = parser.getFiles();
        static constexpr auto iceberg_data_directory = "data";
        auto new_uri = std::filesystem::path(base_configuration.uri.uri.toString()) / iceberg_data_directory
            / MetaParser::generateQueryFromKeys(keys, configuration.format);

        LOG_DEBUG(log, "New uri: {}", new_uri.c_str());
        LOG_DEBUG(log, "Table path: {}", table_path);

        // set new url in configuration
        StorageS3Configuration new_configuration;
        new_configuration.url = new_uri;
        new_configuration.auth_settings.access_key_id = configuration.auth_settings.access_key_id;
        new_configuration.auth_settings.secret_access_key = configuration.auth_settings.secret_access_key;
        new_configuration.format = configuration.format;

        return new_configuration;
    }

    static void processNamedCollectionResult(StorageS3Configuration & configuration, const NamedCollection & collection)
    {
        validateNamedCollection(collection, required_configuration_keys, optional_configuration_keys);

        configuration.url = collection.get<String>("url");

        configuration.auth_settings.access_key_id = collection.getOrDefault<String>("access_key_id", "");
        configuration.auth_settings.secret_access_key = collection.getOrDefault<String>("secret_access_key", "");

        configuration.format = collection.getOrDefault<String>("format", "Parquet");

        configuration.compression_method
            = collection.getOrDefault<String>("compression_method", collection.getOrDefault<String>("compression", "auto"));

        configuration.structure = collection.getOrDefault<String>("structure", "auto");

        configuration.request_settings = S3Settings::RequestSettings(collection);
    }

    static StorageS3Configuration getConfiguration(ASTs & engine_args, ContextPtr local_context)
    {
        StorageS3Configuration configuration;

        if (auto named_collection = tryGetNamedCollectionWithOverrides(engine_args))
        {
            processNamedCollectionResult(configuration, *named_collection);
        }
        else
        {
            /// Supported signatures:
            ///
            /// xx('url')
            /// xx('url', 'format')
            /// xx('url', 'format', 'compression')
            /// xx('url', 'aws_access_key_id', 'aws_secret_access_key', 'format')
            /// xx('url', 'aws_access_key_id', 'aws_secret_access_key', 'format', 'compression')

            if (engine_args.empty() || engine_args.size() > 5)
                throw Exception(
                    ErrorCodes::NUMBER_OF_ARGUMENTS_DOESNT_MATCH,
                    "Storage {} requires 1 to 5 arguments: "
                    "url, [access_key_id, secret_access_key], name of used format and [compression_method]",
                    name);

            auto * header_it = StorageURL::collectHeaders(engine_args, configuration.headers, local_context);
            if (header_it != engine_args.end())
                engine_args.erase(header_it);

            for (auto & engine_arg : engine_args)
                engine_arg = evaluateConstantExpressionOrIdentifierAsLiteral(engine_arg, local_context);

            configuration.url = checkAndGetLiteralArgument<String>(engine_args[0], "url");
            if (engine_args.size() >= 4)
            {
                configuration.auth_settings.access_key_id = checkAndGetLiteralArgument<String>(engine_args[1], "access_key_id");
                configuration.auth_settings.secret_access_key = checkAndGetLiteralArgument<String>(engine_args[2], "secret_access_key");
            }

            if (engine_args.size() == 3 || engine_args.size() == 5)
            {
                configuration.compression_method = checkAndGetLiteralArgument<String>(engine_args.back(), "compression_method");
                configuration.format = checkAndGetLiteralArgument<String>(engine_args[engine_args.size() - 2], "format");
            }
            else if (engine_args.size() != 1)
            {
                configuration.compression_method = "auto";
                configuration.format = checkAndGetLiteralArgument<String>(engine_args.back(), "format");
            }
        }

        if (configuration.format == "auto")
            configuration.format = "Parquet";

        return configuration;
    }

private:

    StorageS3::S3Configuration base_configuration;
    std::shared_ptr<StorageS3> s3engine;
    Poco::Logger * log;
    String table_path;
};

}

#endif
