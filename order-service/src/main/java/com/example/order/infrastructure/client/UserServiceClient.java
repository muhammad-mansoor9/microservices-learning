package com.example.order.infrastructure.client;

import com.example.order.infrastructure.client.dto.UserDto;
import com.example.order.infrastructure.client.exception.UserServiceException;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.core.publisher.Mono;

import java.util.Optional;

@Component
public class UserServiceClient {

    private final WebClient webClient;

    public UserServiceClient(@Qualifier("userServiceWebClient") WebClient webClient) {
        this.webClient = webClient;
    }

    public Optional<UserDto> findById(String userId) {
        return webClient.get()
                .uri("/api/users/{userId}", userId)
                .exchangeToMono(response -> {
                    if (response.statusCode().value() == 404) {
                        return response.releaseBody().then(Mono.empty());
                    }
                    if (response.statusCode().isError()) {
                        return response.createException().flatMap(Mono::error);
                    }
                    return response.bodyToMono(UserDto.class);
                })
                .onErrorMap(e -> !(e instanceof UserServiceException),
                        e -> new UserServiceException("User service error: " + e.getMessage(), e))
                .blockOptional();
    }
}
