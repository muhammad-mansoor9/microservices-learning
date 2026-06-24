package com.example.user.service;

import com.example.user.dto.CreateUserRequest;
import com.example.user.model.User;
import com.example.user.repository.UserRepository;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.util.UUID;

@Service
public class UserService {

    private final UserRepository userRepository;

    public UserService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    public User createUser(CreateUserRequest request) {
        String userId = UUID.randomUUID().toString();
        String createdAt = Instant.now().toString();

        User user = User.builder()
                .userId(userId)
                .email(request.email())
                .name(request.name())
                .createdAt(createdAt)
                .build();

        userRepository.save(user);
        return user;
    }

    public User getUserById(String userId) {
        return userRepository.findById(userId)
                .orElseThrow(() -> new RuntimeException("User not found: " + userId));
    }
}
