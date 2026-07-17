package com.example.user.security;

import lombok.Data;
import org.springframework.stereotype.Component;
import org.springframework.web.context.annotation.RequestScope;

import java.util.List;

@Component
@RequestScope
@Data
public class UserContext {
    private String username;
    private String email;
    private List<String> roles = List.of();
}
