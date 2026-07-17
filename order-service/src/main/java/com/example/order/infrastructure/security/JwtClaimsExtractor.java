package com.example.order.infrastructure.security;

import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Component
public class JwtClaimsExtractor extends JwtAuthenticationConverter {

    private final UserContext userContext;

    public JwtClaimsExtractor(UserContext userContext) {
        this.userContext = userContext;
        // Spring Security calls this converter to produce GrantedAuthorities from the JWT
        setJwtGrantedAuthoritiesConverter(jwt ->
                extractRealmRoles(jwt).stream()
                        .map(r -> new SimpleGrantedAuthority("ROLE_" + r.toUpperCase()))
                        .collect(Collectors.toList())
        );
    }

    @Override
    public AbstractAuthenticationToken convert(Jwt jwt) {
        // Populate the request-scoped bean before returning the token
        List<String> roles = extractRealmRoles(jwt);
        userContext.setUsername(jwt.getClaimAsString("preferred_username"));
        userContext.setEmail(jwt.getClaimAsString("email"));
        userContext.setRoles(roles);

        // super.convert() uses the JwtGrantedAuthoritiesConverter set above
        return super.convert(jwt);
    }

    private List<String> extractRealmRoles(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
        if (realmAccess == null) return List.of();
        Object roles = realmAccess.get("roles");
        if (!(roles instanceof List<?> list)) return List.of();
        return list.stream().map(Object::toString).toList();
    }
}
