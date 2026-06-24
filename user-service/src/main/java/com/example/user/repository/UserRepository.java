package com.example.user.repository;

import com.example.user.model.User;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Repository;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemResponse;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

import java.util.Map;
import java.util.Optional;

@Repository
public class UserRepository {

    private final DynamoDbClient dynamoDbClient;
    private final String tableName;

    public UserRepository(DynamoDbClient dynamoDbClient,
                          @Value("${aws.dynamodb.table-name:users}") String tableName) {
        this.dynamoDbClient = dynamoDbClient;
        this.tableName = tableName;
    }

    public void save(User user) {
        Map<String, AttributeValue> item = Map.of(
                "userId",    AttributeValue.fromS(user.getUserId()),
                "email",     AttributeValue.fromS(user.getEmail()),
                "name",      AttributeValue.fromS(user.getName()),
                "createdAt", AttributeValue.fromS(user.getCreatedAt())
        );

        dynamoDbClient.putItem(PutItemRequest.builder()
                .tableName(tableName)
                .item(item)
                .build());
    }

    public Optional<User> findById(String userId) {
        GetItemResponse response = dynamoDbClient.getItem(GetItemRequest.builder()
                .tableName(tableName)
                .key(Map.of("userId", AttributeValue.fromS(userId)))
                .build());

        Map<String, AttributeValue> item = response.item();
        if (item == null || !item.containsKey("userId")) {
            return Optional.empty();
        }

        User user = User.builder()
                .userId(item.get("userId").s())
                .email(item.get("email").s())
                .name(item.get("name").s())
                .createdAt(item.get("createdAt").s())
                .build();

        return Optional.of(user);
    }
}
