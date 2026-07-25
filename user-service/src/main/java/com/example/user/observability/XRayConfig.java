package com.example.user.observability;

import com.amazonaws.xray.AWSXRay;
import com.amazonaws.xray.AWSXRayRecorderBuilder;
import com.amazonaws.xray.plugins.ECSPlugin;
import com.amazonaws.xray.strategy.sampling.LocalizedSamplingStrategy;
import jakarta.annotation.PostConstruct;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

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
    public FilterRegistrationBean<XRaySegmentFilter> xRayServletFilter() {
        FilterRegistrationBean<XRaySegmentFilter> registration =
                new FilterRegistrationBean<>(new XRaySegmentFilter(serviceName));
        registration.addUrlPatterns("/*");
        registration.setOrder(Ordered.HIGHEST_PRECEDENCE);
        return registration;
    }

    static class XRaySegmentFilter extends OncePerRequestFilter {
        private final String segmentName;

        XRaySegmentFilter(String segmentName) {
            this.segmentName = segmentName;
        }

        @Override
        protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                        FilterChain filterChain) throws ServletException, IOException {
            AWSXRay.beginSegment(segmentName);
            try {
                filterChain.doFilter(request, response);
            } catch (Exception e) {
                AWSXRay.getCurrentSegment().addException(e);
                throw e;
            } finally {
                AWSXRay.endSegment();
            }
        }
    }
}
