package com.example.user.security;

import lombok.RequiredArgsConstructor;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;

@Component
@RequiredArgsConstructor
public class JwtClaimsExtractor {

    private final UserContext userContext;

    public void populate() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth instanceof JwtAuthenticationToken jwtAuth) {
            Jwt jwt = jwtAuth.getToken();
            userContext.setUsername(jwt.getClaimAsString("preferred_username"));
            userContext.setEmail(jwt.getClaimAsString("email"));
            userContext.setRoles(extractRealmRoles(jwt));
        } else if (auth != null && isInternal(auth)) {
            userContext.setUsername("internal");
            userContext.setRoles(List.of("INTERNAL"));
        }
    }

    private boolean isInternal(Authentication auth) {
        return auth.getAuthorities().stream()
                .anyMatch(a -> a.getAuthority().equals("INTERNAL"));
    }

    private List<String> extractRealmRoles(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
        if (realmAccess == null) return List.of();
        Object roles = realmAccess.get("roles");
        if (!(roles instanceof List<?> list)) return List.of();
        return list.stream().map(Object::toString).toList();
    }
}
