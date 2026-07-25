package com.example.user.observability;

import com.amazonaws.xray.AWSXRay;
import com.amazonaws.xray.AWSXRayRecorderBuilder;
import com.amazonaws.xray.jakarta.servlet.AWSXRayServletFilter;
import com.amazonaws.xray.plugins.ECSPlugin;
import com.amazonaws.xray.strategy.sampling.LocalizedSamplingStrategy;
import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

@Configuration
public class XRayConfig {

    @Value("${spring.application.name:user-service}")
    private String serviceName;

    @PostConstruct
    void initRecorder() {
        AWSXRayRecorderBuilder builder = AWSXRayRecorderBuilder.standard()
                .withPlugin(new ECSPlugin())
                .withSamplingStrategy(new LocalizedSamplingStrategy());
        AWSXRay.setGlobalRecorder(builder.build());
    }

    @Bean
    public FilterRegistrationBean<AWSXRayServletFilter> xRayServletFilter() {
        FilterRegistrationBean<AWSXRayServletFilter> registration =
                new FilterRegistrationBean<>(new AWSXRayServletFilter(serviceName));
        registration.addUrlPatterns("/*");
        registration.setOrder(Ordered.HIGHEST_PRECEDENCE);
        return registration;
    }
}
